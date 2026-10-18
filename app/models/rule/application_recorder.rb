# Captures the prior and applied values of the attributes a rule changes during
# an undoable apply-all run.
#
# Snapshot and diff are done around `Rule#apply`, so the record contains only
# attributes that actually changed after claimed ids, locks and no-ops are
# taken into account. Queries are batched and preload the entry and tags, so a
# rule matching many transactions does not produce an N+1 of its own.
class Rule::ApplicationRecorder
  ATTRIBUTES_BY_ACTION = {
    "set_transaction_category" => %w[category_id],
    "set_transaction_merchant" => %w[merchant_id],
    "set_transaction_name" => %w[name],
    "set_transaction_tags" => %w[tag_ids],
    "exclude_transaction" => %w[excluded],
    "set_investment_activity_label" => %w[investment_activity_label]
  }.freeze

  def initialize(rule:, actor:, batch_id:)
    @rule = rule
    @actor = actor
    @batch_id = batch_id
  end

  # Never lets a recording failure abort the rule run itself: the run has
  # already changed data, and losing the undo row must not turn that into a
  # failed application.
  def snapshot(transaction_ids)
    @snapshot = {}
    return if attributes.empty? || transaction_ids.empty?

    transactions_for(transaction_ids).each do |transaction|
      @snapshot[transaction.id] = values_for(transaction)
    end
  rescue => e
    @snapshot = nil
    log_failure("snapshot", e)
  end

  def record!(rule_run: nil)
    return if @snapshot.blank?

    changes = {}
    transactions_for(@snapshot.keys).each do |transaction|
      before = @snapshot[transaction.id]
      next if before.nil?

      diff = {}
      attributes.each do |attribute|
        from = before[attribute]
        to = value_for(transaction, attribute)
        diff[attribute] = { "from" => from, "to" => to } unless same_value?(from, to)
      end
      changes[transaction.id] = diff if diff.any?
    end

    return if changes.empty?

    RuleApplication.create!(
      family: rule.family,
      rule: rule,
      user: actor,
      rule_run: rule_run,
      batch_id: batch_id,
      applied_at: Time.current,
      transaction_ids: changes.keys,
      attribute_changes: changes
    )
  rescue => e
    log_failure("record", e)
  end

  private
    attr_reader :rule, :actor, :batch_id

    def attributes
      @attributes ||= rule.actions.flat_map { |action| ATTRIBUTES_BY_ACTION.fetch(action.action_type, []) }.uniq
    end

    def transactions_for(transaction_ids)
      rule.family.transactions
          .where("transactions.id = ANY(?::uuid[])", PG::TextEncoder::Array.new.encode(transaction_ids))
          .includes(:entry, :tags)
    end

    def values_for(transaction)
      attributes.index_with { |attribute| value_for(transaction, attribute) }
    end

    def value_for(transaction, attribute)
      if RuleApplication::ENTRY_ATTRIBUTES.include?(attribute)
        transaction.entry.public_send(attribute)
      else
        transaction.public_send(attribute)
      end
    end

    def same_value?(left, right)
      if left.is_a?(Array) || right.is_a?(Array)
        Array(left).map(&:to_s).sort == Array(right).map(&:to_s).sort
      else
        left == right
      end
    end

    def log_failure(stage, error)
      message = "Rule application #{stage} failed for rule #{rule.id}: #{error.class}: #{error.message}"
      Rails.logger.error(message)
      DebugLogEntry.capture(
        category: "rule_application",
        level: "error",
        message: message,
        source: self.class.name,
        family: rule.family,
        user: actor,
        metadata: {
          rule_id: rule.id,
          batch_id: batch_id,
          stage: stage,
          error_class: error.class.name,
          error_message: error.message
        }
      )
    rescue => e
      # Logging a recording failure must itself never break the run.
      Rails.logger.error("Rule application #{stage} failure could not be logged: #{e.class}: #{e.message}")
    end
end
