# frozen_string_literal: true

# Records the financial fields a model actually changed. Include it next to the
# class-level declaration:
#
#   include Auditable
#   audit_financial_attributes :category_id, :merchant_id
#
# The write happens after commit, so a rolled-back edit leaves no trail, and
# `saved_changes` is narrowed to the declared fields — notes, tags, sync
# bookkeeping and provider metadata never reach the audit row. A save whose
# declared fields are unchanged (including a touch) records nothing.
#
# Entry includes it too and points the audit at its Transaction, so an amount
# or date edit is one transaction-level event rather than an entry-level one.
module Auditable
  extend ActiveSupport::Concern

  included do
    after_commit :record_auditable_change, on: :update
  end

  class_methods do
    def audit_financial_attributes(*attributes)
      @audit_financial_attributes = attributes.map(&:to_s).freeze
    end

    def audited_financial_attributes
      @audit_financial_attributes || []
    end
  end

  private
    # The record the trail hangs off. Entry overrides this to its Transaction.
    def audit_target
      self
    end

    def audit_family
      AuditLog.family_for(audit_target)
    end

    def audit_action
      "#{audit_target.model_name.singular}.updated"
    end

    def audit_currency
      if respond_to?(:currency)
        currency
      elsif audit_target.respond_to?(:entry)
        audit_target.entry&.currency
      end
    end

    def record_auditable_change
      target = audit_target
      family = audit_family
      return if target.nil? || family.nil?

      changes = saved_changes.slice(*self.class.audited_financial_attributes)
      changes.delete("updated_at")
      return if changes.empty?

      AuditLog.record!(
        auditable: target,
        family: family,
        action: audit_action,
        before: audit_snapshot(changes, 0),
        after: audit_snapshot(changes, 1),
        metadata: {
          "fields" => changes.keys,
          "currency" => audit_currency
        }
      )
    rescue => error
      # The financial write already committed. A trail write must be visible in
      # the logs, but it cannot turn a successful edit into a 500.
      Rails.logger.error("Auditable audit write failed for #{self.class.name} #{id}: #{error.class}: #{error.message}")
    end

    def audit_snapshot(changes, index)
      changes.each_with_object({}) do |(attribute, values), snapshot|
        value = values[index]
        snapshot[attribute] = audit_raw_value(attribute, value)

        if (label_attribute = AuditLog::LABEL_ATTRIBUTES[attribute])
          snapshot[label_attribute] = audit_label(attribute, value)
        end
      end
    end

    def audit_raw_value(attribute, value)
      case attribute
      when "amount", "opening_balance", "closing_balance"
        value.is_a?(BigDecimal) ? value.to_s("F") : value&.to_s
      when "date", "period_start_on", "period_end_on"
        value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
      else
        value
      end
    end

    def audit_label(attribute, value)
      return nil if value.blank?

      case attribute
      when "category_id" then audit_family&.categories&.find_by(id: value)&.name
      when "merchant_id" then audit_family&.merchants&.find_by(id: value)&.name
      when "account_id" then audit_family&.accounts&.find_by(id: value)&.name
      end
    end
end
