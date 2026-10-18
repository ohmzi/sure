# One rule's part of an undoable apply-all run.
#
# A batch is identified by `batch_id`; every rule that ran in the same
# apply-all gets a row sharing it. `attribute_changes` maps a transaction id to the
# attributes the rule changed, each with the value before (`from`) and after
# (`to`) the application. Undo restores `from` only while the current value is
# still `to`, so a transaction the owner edited afterwards is skipped and
# listed in `skipped_transaction_ids` instead of being clobbered.
class RuleApplication < ApplicationRecord
  class AlreadyUndone < StandardError; end

  APPLIED = "applied"
  UNDONE = "undone"
  PARTIALLY_UNDONE = "partially_undone"
  STATUSES = [ APPLIED, UNDONE, PARTIALLY_UNDONE ].freeze

  # Attributes stored on the entry rather than the transaction.
  ENTRY_ATTRIBUTES = %w[name excluded].freeze

  belongs_to :family
  belongs_to :rule
  belongs_to :user, optional: true
  belongs_to :rule_run, optional: true

  validates :batch_id, :applied_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :applied, -> { where(undone_at: nil) }
  scope :recent, -> { order(applied_at: :desc, created_at: :desc) }

  def applied?
    undone_at.nil?
  end

  # Undoes every rule application recorded in the batch, newest first so
  # additive changes (tags) unwind in the order they were applied.
  #
  # The same family advisory key Rule::Runner uses is held for the whole batch,
  # so an undo cannot interleave with an apply-all or nightly run. Raises
  # AlreadyUndone when the batch has nothing left to undo, which is what makes a
  # second undo request a refusal rather than a silent no-op.
  def self.undo_batch!(family:, batch_id:, actor: nil)
    applications = family.rule_applications.where(batch_id: batch_id).order(:created_at, :id).to_a
    raise ActiveRecord::RecordNotFound if applications.empty?
    raise AlreadyUndone if applications.all? { |application| application.undone_at.present? }

    transaction do
      lock_family_rules(family)

      applications.reverse_each { |application| application.undo!(actor: actor) }
    end
  end

  # Transaction-scoped form of the lock the runner takes, so it is released with
  # the undo transaction even if the process dies mid-restore.
  def self.lock_family_rules(family)
    connection = ActiveRecord::Base.lease_connection
    # execute rather than select_value: pg_advisory_xact_lock returns void, and
    # asking AR to type-cast it logs an unknown-OID warning.
    connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "SELECT pg_advisory_xact_lock(?)",
        Rule::Runner.advisory_lock_key(family.id)
      ])
    )
  end
  private_class_method :lock_family_rules

  # Restores the recorded prior values for this rule application. Returns false
  # when it was already undone.
  def undo!(actor: nil)
    with_lock do
      next false if undone_at.present?

      skipped = []
      attribute_changes.each do |transaction_id, attributes|
        skipped << transaction_id unless restore_if_unchanged(transaction_id, attributes)
      end

      update!(
        undone_at: Time.current,
        undone_by_id: actor&.id,
        skipped_transaction_ids: skipped,
        status: skipped.empty? ? UNDONE : PARTIALLY_UNDONE
      )
      true
    end
  end

  private
    # Locks the row before re-reading it. The check and the write are then one
    # critical section: a user edit that lands in between either completes
    # before the lock (and is seen by the check) or waits for the restore.
    def restore_if_unchanged(transaction_id, attributes)
      restored = false

      self.class.transaction do
        transaction = family.transactions.lock.includes(:entry).find_by(id: transaction_id)
        next if transaction.nil? || transaction.entry.nil?

        transaction.entry.lock!

        unless edited_after_apply?(transaction, attributes)
          restore!(transaction, attributes)
          restored = true
        end
      end

      restored
    end
    # A row counts as edited when any attribute the rule changed no longer
    # holds the value the rule wrote. We skip the whole row rather than
    # restoring only the untouched attributes, so a partial undo never leaves a
    # transaction with a mix of old and new rule values the owner did not
    # choose.
    def edited_after_apply?(transaction, attributes)
      attributes.any? do |attribute, change|
        !same_value?(current_value(transaction, attribute), change["to"])
      end
    end

    def restore!(transaction, attributes)
      transaction_values = {}
      entry_values = {}

      attributes.each do |attribute, change|
        if ENTRY_ATTRIBUTES.include?(attribute)
          entry_values[attribute] = change["from"]
        else
          transaction_values[attribute] = change["from"]
        end
      end

      transaction.update!(transaction_values) if transaction_values.any?
      transaction.entry.update!(entry_values) if entry_values.any?
    end

    def current_value(transaction, attribute)
      if ENTRY_ATTRIBUTES.include?(attribute)
        transaction.entry.public_send(attribute)
      else
        transaction.public_send(attribute)
      end
    end

    def same_value?(current, recorded)
      if current.is_a?(Array) || recorded.is_a?(Array)
        Array(current).map(&:to_s).sort == Array(recorded).map(&:to_s).sort
      else
        current == recorded
      end
    end
end
