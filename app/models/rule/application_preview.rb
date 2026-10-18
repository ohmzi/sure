# Read-only simulation of what an apply-all run would change.
#
# Rule::Runner re-reads each rule's matches after the rules above have mutated
# transactions, so a lower rule can match a renamed transaction or find a tag
# already added. The preview has to follow the same sequence to promise the
# same set. It loads the family's transactions once, keeps a per-transaction
# copy of the mutable attributes, and evaluates each rule against that copy as
# it applies the rule's synchronous actions in memory. Immutable conditions
# (amount, type, details, notes, account) are evaluated once by the existing
# filter SQL instead of reimplementing their predicates.
#
# No per-transaction queries are issued, and nothing is written: the
# confirmation page can render large runs without an N+1 or a write.
#
# Async actions (AI categorization/merchant detection) run later in background
# jobs, and transfer/notification actions do work that cannot be expressed as an
# attribute restore. Those are reported as a count and marked as not undoable.
class Rule::ApplicationPreview
  Group = Struct.new(:from, :to, :count, keyword_init: true)
  Change = Struct.new(:rule, :action, :action_type, :total, :groups, :undoable, keyword_init: true)

  MUTABLE_CONDITION_TYPES = %w[
    transaction_name
    transaction_category
    transaction_merchant
    transaction_tag
  ].freeze

  ASYNC_ACTIONS = %w[auto_categorize auto_detect_merchants].freeze

  def initialize(family)
    @family = family
    @category_names = family.categories.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @merchant_names = family.merchants.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @tag_names = family.tags.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @account_ids = family.accounts.pluck(:id).to_set
    @transactions = load_transactions
    @transactions_by_id = @transactions.index_by(&:id)
    @states = @transactions.to_h { |transaction| [ transaction.id, initial_state(transaction) ] }
    @immutable_condition_ids = {}
  end

  # Returns one Change per (rule, action) that would modify at least one
  # transaction, in rule and action order.
  def changes
    claimed_ids = Hash.new { |hash, attribute| hash[attribute] = Set.new }
    stopped_ids = Set.new
    result = []

    family.rules.ordered.includes(:actions, conditions: :sub_conditions).each do |rule|
      matched_ids = matching_ids(rule).reject { |transaction_id| stopped_ids.include?(transaction_id) }

      rule.actions.each do |action|
        excluded_ids = Rule::ActionClaims.excluded_ids(action, claimed_ids)
        action_ids = matched_ids.reject { |transaction_id| excluded_ids.include?(transaction_id) }

        change = build_change(rule, action, action_ids)
        result << change if change
        apply_action_effect(action, action_ids)
      end

      rule.actions.each { |action| Rule::ActionClaims.record(action, matched_ids, claimed_ids) }
      stopped_ids.merge(matched_ids) if rule.stop_processing?
    end

    result
  end

  private
    attr_reader :family, :category_names, :merchant_names, :tag_names, :account_ids,
                :transactions, :transactions_by_id, :states

    def load_transactions
      family.transactions
            .visible
            .merge(Entry.excluding_split_parents)
            .includes(:entry, :tags)
            .to_a
    end

    def initial_state(transaction)
      {
        name: transaction.entry.name,
        category_id: transaction.category_id,
        merchant_id: transaction.merchant_id,
        tag_ids: transaction.tags.map(&:id),
        excluded: transaction.entry.excluded,
        investment_activity_label: transaction.investment_activity_label
      }
    end

    def matching_ids(rule)
      transactions.each_with_object(Set.new) do |transaction, ids|
        next unless in_effective_window?(transaction, rule)
        next unless rule.conditions.all? { |condition| condition_matches?(transaction, condition) }

        ids << transaction.id
      end
    end

    def in_effective_window?(transaction, rule)
      return true if rule.effective_date.blank?

      transaction.entry.date.present? && transaction.entry.date >= rule.effective_date
    end

    # Mirrors Rule::Condition's tree. Name/category/merchant/tag are evaluated
    # against the simulated state; every other leaf is a row-level predicate
    # that rule updates cannot affect, so its existing filter query supplies the
    # matching ids.
    def condition_matches?(transaction, condition)
      if condition.compound?
        sub_conditions = condition.sub_conditions
        return true if sub_conditions.empty?

        if condition.operator == "or"
          sub_conditions.any? { |sub| condition_matches?(transaction, sub) }
        else
          sub_conditions.all? { |sub| condition_matches?(transaction, sub) }
        end
      else
        state = states.fetch(transaction.id)

        case condition.condition_type
        when "transaction_name"
          name_matches?(transaction, state[:name], condition.operator, condition.value)
        when "transaction_category"
          select_matches?(state[:category_id], condition.operator, condition.value)
        when "transaction_merchant"
          select_matches?(state[:merchant_id], condition.operator, condition.value)
        when "transaction_tag"
          tag_condition_matches?(state[:tag_ids], condition.operator, condition.value)
        else
          immutable_condition_ids(condition).include?(transaction.id)
        end
      end
    rescue => e
      # A malformed legacy condition would fail the real run too. Keep the
      # preview renderable rather than turning the confirmation page into a 500.
      Rails.logger.warn("Rule::ApplicationPreview could not evaluate condition #{condition.id}: #{e.class}: #{e.message}")
      false
    end

    def immutable_condition_ids(condition)
      @immutable_condition_ids[condition.object_id] ||= begin
        scope = condition.prepare(base_scope)
        condition.apply(scope).pluck(:id).to_set
      rescue => e
        Rails.logger.warn("Rule::ApplicationPreview could not query condition #{condition.id}: #{e.class}: #{e.message}")
        Set.new
      end
    end

    def base_scope
      family.transactions.visible.merge(Entry.excluding_split_parents)
    end

    def name_matches?(transaction, name, operator, value)
      normalized_name = normalize_text(name)
      normalized_value = normalize_text(value)

      case operator
      when "like"
        normalized_name.present? && normalized_name.downcase.include?(normalized_value.downcase)
      when "not_like"
        normalized_name.nil? || !normalized_name.downcase.include?(normalized_value.downcase)
      when "matches"
        normalized_name.present? && Regexp.new(value.to_s, Regexp::IGNORECASE).match?(normalized_name)
      when "not_matches"
        normalized_name.nil? || !Regexp.new(value.to_s, Regexp::IGNORECASE).match?(normalized_name)
      when "="
        plaid_name_equal?(transaction, normalized_name, normalized_value)
      when "!="
        !plaid_name_equal?(transaction, normalized_name, normalized_value)
      when "is_null"
        name.nil?
      when "is_not_null"
        !name.nil?
      else
        false
      end
    end

    # Matches TransactionName's Plaid-aware equality: a Plaid row also equals
    # the value when its name is the value joined to the stored original
    # description by the processor's separator.
    def plaid_name_equal?(transaction, normalized_name, normalized_value)
      return false if normalized_name.nil?
      return true if normalized_name == normalized_value

      entry = transaction.entry
      original_description = transaction.extra&.dig("plaid", "original_description")
      return false unless entry.source == PlaidEntry::Processor::SOURCE && original_description.present?

      composed = normalize_text("#{normalized_value}#{PlaidEntry::Processor::NAME_SEPARATOR}#{original_description}")
      normalized_name == composed
    end

    def normalize_text(value)
      return nil if value.nil?

      value.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    def select_matches?(current_value, operator, expected_value)
      current = current_value&.to_s
      expected = expected_value&.to_s

      case operator
      when "="
        current == expected
      when "!="
        current != expected
      when "is_null"
        current.nil?
      when "is_not_null"
        !current.nil?
      else
        false
      end
    end

    def tag_condition_matches?(tag_ids, operator, value)
      case operator
      when "="
        tag_ids.include?(value.to_s)
      when "is_null"
        tag_ids.empty?
      else
        false
      end
    end

    def build_change(rule, action, ids)
      return if ids.empty?

      case action.action_type
      when "set_transaction_category"
        category_change(rule, action, ids)
      when "set_transaction_merchant"
        merchant_change(rule, action, ids)
      when "set_transaction_name"
        name_change(rule, action, ids)
      when "set_transaction_tags"
        tag_change(rule, action, ids)
      when "exclude_transaction"
        excluded_change(rule, action, ids)
      when "set_investment_activity_label"
        investment_label_change(rule, action, ids)
      when *ASYNC_ACTIONS
        async_change(rule, action, ids)
      when "set_as_transfer_or_payment"
        transfer_change(rule, action, ids)
      when "send_email_notification"
        notification_change(rule, action, ids)
      end
    end

    def category_change(rule, action, ids)
      target_name = category_names[action.value]
      return if target_name.nil?

      counts = Hash.new(0)
      ids.each do |transaction_id|
        current = states.fetch(transaction_id)[:category_id]
        counts[current] += 1 unless current&.to_s == action.value.to_s
      end
      return if counts.empty?

      groups = counts.map do |current, count|
        Group.new(from: category_names[current], to: target_name, count: count)
      end
      build_undoable_change(rule, action, groups)
    end

    def merchant_change(rule, action, ids)
      target_name = merchant_names[action.value]
      return if target_name.nil?

      counts = Hash.new(0)
      ids.each do |transaction_id|
        current = states.fetch(transaction_id)[:merchant_id]
        counts[current] += 1 unless current&.to_s == action.value.to_s
      end
      return if counts.empty?

      groups = counts.map do |current, count|
        Group.new(from: merchant_names[current], to: target_name, count: count)
      end
      build_undoable_change(rule, action, groups)
    end

    def name_change(rule, action, ids)
      return if action.value.blank?

      counts = Hash.new(0)
      ids.each do |transaction_id|
        current = states.fetch(transaction_id)[:name]
        counts[current] += 1 unless current == action.value
      end
      return if counts.empty?

      groups = counts.map { |current, count| Group.new(from: current, to: action.value, count: count) }
      build_undoable_change(rule, action, groups)
    end

    def tag_change(rule, action, ids)
      selected_tag_ids = valid_tag_ids(action.value)
      return if selected_tag_ids.empty?

      count = ids.count do |transaction_id|
        (selected_tag_ids - states.fetch(transaction_id)[:tag_ids]).any?
      end
      return if count.zero?

      names = selected_tag_ids.map { |tag_id| tag_names[tag_id] }.join(", ")
      build_undoable_change(rule, action, [ Group.new(from: nil, to: names, count: count) ])
    end

    def excluded_change(rule, action, ids)
      count = ids.count { |transaction_id| states.fetch(transaction_id)[:excluded] != true }
      return if count.zero?

      build_undoable_change(rule, action, [ Group.new(from: false, to: true, count: count) ])
    end

    def investment_label_change(rule, action, ids)
      return unless Transaction::ACTIVITY_LABELS.include?(action.value)

      counts = Hash.new(0)
      ids.each do |transaction_id|
        current = states.fetch(transaction_id)[:investment_activity_label]
        counts[current] += 1 unless current == action.value
      end
      return if counts.empty?

      groups = counts.map { |current, count| Group.new(from: current, to: action.value, count: count) }
      build_undoable_change(rule, action, groups)
    end

    def async_change(rule, action, ids)
      attribute = action.action_type == "auto_categorize" ? :category_id : :merchant_id
      count = ids.count { |transaction_id| transactions_by_id.fetch(transaction_id).enrichable?(attribute) }
      return if count.zero?

      Change.new(rule: rule, action: action, action_type: action.action_type, total: count, groups: [], undoable: false)
    end

    def transfer_change(rule, action, ids)
      return unless account_ids.include?(action.value)

      count = ids.count { |transaction_id| !transactions_by_id.fetch(transaction_id).transfer? }
      return if count.zero?

      Change.new(rule: rule, action: action, action_type: action.action_type, total: count, groups: [], undoable: false)
    end

    def notification_change(rule, action, ids)
      delivered = NotificationDelivery
        .where(rule_id: rule.id, transaction_id: ids)
        .pluck(:transaction_id)
        .to_set
      count = ids.count { |transaction_id| !delivered.include?(transaction_id) }
      return if count.zero?

      Change.new(rule: rule, action: action, action_type: action.action_type, total: count, groups: [], undoable: false)
    end

    def build_undoable_change(rule, action, groups)
      Change.new(
        rule: rule,
        action: action,
        action_type: action.action_type,
        total: groups.sum(&:count),
        groups: groups.sort_by { |group| -group.count },
        undoable: true
      )
    end

    def valid_tag_ids(value)
      Rule::Action.decode_multi_value_names(value).select { |tag_id| tag_names.key?(tag_id) }
    end

    # Applies the rule's synchronous attribute writes to the simulated state so
    # lower rules see the same values they would read from the database.
    def apply_action_effect(action, ids)
      case action.action_type
      when "set_transaction_category"
        return unless category_names.key?(action.value)

        ids.each { |transaction_id| states.fetch(transaction_id)[:category_id] = action.value }
      when "set_transaction_merchant"
        return unless merchant_names.key?(action.value)

        ids.each { |transaction_id| states.fetch(transaction_id)[:merchant_id] = action.value }
      when "set_transaction_name"
        return if action.value.blank?

        ids.each { |transaction_id| states.fetch(transaction_id)[:name] = action.value }
      when "set_transaction_tags"
        tag_ids = valid_tag_ids(action.value)
        return if tag_ids.empty?

        ids.each { |transaction_id| states.fetch(transaction_id)[:tag_ids] |= tag_ids }
      when "exclude_transaction"
        ids.each { |transaction_id| states.fetch(transaction_id)[:excluded] = true }
      when "set_investment_activity_label"
        return unless Transaction::ACTIVITY_LABELS.include?(action.value)

        ids.each { |transaction_id| states.fetch(transaction_id)[:investment_activity_label] = action.value }
      end
      # Async, transfer and notification actions do not change a matching
      # attribute synchronously.
    end
end
