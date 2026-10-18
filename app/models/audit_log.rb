# frozen_string_literal: true

# Append-only trail of financial edits. A row answers "who changed what, when,
# and from which request" for the household's own records.
#
# Immutability is enforced at the model layer: there is no update route, and
# both persistence paths that could rewrite history raise
# ActiveRecord::ReadOnlyRecord. Deletes are deliberately not cascaded from the
# audited record (except when the whole family is destroyed), so a removed
# transaction or statement still has its history.
#
# == Failure policy
#
# There are exactly two write paths, and the caller picks one deliberately:
#
# * +record!+ is strict. Call it inside the same database transaction as the
#   change it describes; if the trail write fails, the change rolls back with
#   it. Never use it for work that has already committed.
# * +record_best_effort!+ is for post-commit or irreversible actions (enqueued
#   jobs, filesystem/byte deletion, +after_commit+ callbacks). It logs the
#   failure and swallows it, so a trail write can never turn an edit that
#   already succeeded into a 500.
#
# == Append-only below the model
#
# Rails callbacks cannot stop +update_all+ / +delete_all+, which bypass the
# model. Application code must not use them on this table: the only permitted
# bulk delete is +purge_for_family!+, called from Family's destroy callback when
# a household is deleted (the tenant-purge exception). The database foreign key
# cascade is the last line for a family deleted without callbacks. A lint-style
# test in test/models/audit_log_test.rb keeps direct bulk writes out of app/.
class AuditLog < ApplicationRecord
  ACTIONS = %w[
    transaction.updated
    account_statement.updated
    account_statement.reviewed
    account_statement.deleted
    import.published
    import.reverted
    import.deleted
    document.deleted
    family_export.created
    category.merged
    transactions.bulk_recategorized
    merchant.merged
    merchant.converted
    merchant.unlinked
  ].freeze

  # Keys that must never reach an audit row. The recorder only ever receives
  # explicit financial fields, but a future caller should not be able to leak a
  # token, provider payload, API key, certificate or encrypted blob by accident.
  FORBIDDEN_KEY = /token|secret|password|authorization|cookie|raw_response|raw_payload|payload|api_key|certificate|encrypt/i

  # Attributes whose raw id is paired with a display name, snapshotted at edit
  # time so a later rename or delete cannot rewrite the trail.
  LABEL_ATTRIBUTES = {
    "category_id" => "category_name",
    "merchant_id" => "merchant_name",
    "account_id" => "account_name"
  }.freeze

  belongs_to :family
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :auditable, polymorphic: true, optional: true

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validate :family_owns_auditable

  before_validation :refuse_mutation, on: :update
  before_destroy :refuse_mutation
  before_validation :derive_family, if: -> { family.nil? && auditable.present? }

  scope :for_family, ->(family) { where(family: family) }
  scope :for_auditable, ->(record) { where(auditable: record) }
  scope :recent_first, -> { order(created_at: :desc) }

  class << self
    # Strict write path. `actor`, `request_id` and `source` default to the
    # request context, so a controller does not have to pass them. Call inside
    # the transaction that makes the change; a failure aborts both.
    def record!(auditable:, action:, before: nil, after: nil, metadata: {}, actor: nil, request_id: nil, source: nil, family: nil)
      family ||= family_for(auditable)
      raise ArgumentError, "cannot audit a record without a family" if family.nil?

      effective_actor = actor.nil? ? Current.user : actor
      trail_metadata = sanitize(metadata).merge(
        "source" => source.presence || Current.audit_source.presence || "system"
      )

      # An impersonated user is the actor of the edit; the admin behind the
      # impersonation is recorded alongside it so attribution is honest.
      if (true_user = Current.true_user) && true_user != effective_actor
        trail_metadata["true_user_id"] = true_user.id
      end

      create!(
        family: family,
        auditable: auditable,
        actor: effective_actor,
        action: action,
        before: sanitize(before) || {},
        after: sanitize(after) || {},
        request_id: request_id.nil? ? Current.request_id : request_id,
        metadata: trail_metadata
      )
    end

    # Best-effort write path for changes that are already committed or cannot
    # be rolled back (an enqueued job, deleted bytes, an after_commit callback).
    # A failed trail write is logged, never raised into the successful caller.
    def record_best_effort!(**arguments)
      record!(**arguments)
    rescue => error
      auditable = arguments[:auditable]
      context = auditable ? " on #{auditable.class.name} #{auditable.try(:id)}" : ""
      Rails.logger.error(
        "Audit write failed for #{arguments[:action]}#{context}: #{error.class}: #{error.message}"
      )
      nil
    end

    # The tenant-purge exception: deleting a household deletes its own trail.
    # This is the only permitted bulk delete; see the class comment.
    def purge_for_family!(family)
      where(family_id: family.id).delete_all
    end

    # Resolves the owning household from any audited model without requiring
    # every model to define `family` (Transaction reaches it through its entry,
    # Entry through its account).
    def family_for(record)
      return nil if record.nil?

      if record.respond_to?(:family) && record.family
        record.family
      elsif record.respond_to?(:entry) && record.entry
        family_for(record.entry)
      elsif record.respond_to?(:account) && record.account
        family_for(record.account)
      end
    end

    private
      def sanitize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), result|
            next if key.to_s.match?(FORBIDDEN_KEY)

            result[key] = sanitize(nested)
          end
        when Array
          value.map { |nested| sanitize(nested) }
        else
          value
        end
      end
  end

  private
    def refuse_mutation
      raise ActiveRecord::ReadOnlyRecord, "Audit logs are append-only"
    end

    def derive_family
      self.family = self.class.family_for(auditable)
    end

    def family_owns_auditable
      return if auditable.blank? || family.blank?

      owner = self.class.family_for(auditable)
      return if owner.nil? || owner.id == family_id

      errors.add(:family, "must own the audited record")
    end
end
