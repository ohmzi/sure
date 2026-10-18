# Read-only simulation of what an apply-all run would change.
#
# Rule::Runner re-reads each rule's matches after the rules above have mutated
# transactions, so a lower rule can match a renamed transaction or find a tag
# already added. The preview follows the same sequence: each rule's initial
# candidate ids come from one SQL query (its own Rule#matching_scope), and only
# the rows a higher rule actually changed are re-evaluated in Ruby. It never
# loads the family's whole transaction table.
#
# A per-transaction copy of the mutable attributes is kept for rows in a rule's
# match set. Immutable conditions (amount, details, notes, account) are answered
# by the existing filter SQL; the mutable ones (name, category, merchant, tags,
# and the kind a transfer action rewrites) are evaluated against the copy.
#
# Nothing is written. Async actions run later in background jobs, and transfer
# and notification actions do work that cannot be expressed as an attribute
# restore; those are reported as a count and marked as not undoable.
class Rule::ApplicationPreview
  Group = Struct.new(:from, :to, :count, keyword_init: true)
  Change = Struct.new(:rule, :action, :action_type, :total, :groups, :undoable, keyword_init: true)

  ASYNC_ACTIONS = %w[auto_categorize auto_detect_merchants].freeze

  def initialize(family)
    @family = family
    @category_names = family.categories.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @merchant_names = family.merchants.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @tag_names = family.tags.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @accounts_by_id = family.accounts.index_by(&:id)
    @investment_contributions_category_id = existing_category(Category.all_investment_contributions_names)
    @credit_card_payment_category_id = existing_credit_card_payment_category
    @transactions_by_id = {}
    @states = {}
    @overridden_ids = Set.new
    @synthetic_ids = Set.new
    @immutable_condition_ids = {}
  end

  # Returns one Change per (rule, action) that would modify at least one
  # transaction, in rule and action order.
  def changes
    claimed_ids = Hash.new { |hash, attribute| hash[attribute] = Set.new }
    stopped_ids = Set.new
    result = []

    family.rules.ordered.includes(:actions, conditions: :sub_conditions).each do |rule|
      matched_ids = matching_ids(rule, stopped_ids)

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
    attr_reader :family, :category_names, :merchant_names, :tag_names, :accounts_by_id,
                :transactions_by_id, :states, :overridden_ids, :synthetic_ids

    # The rule's own SQL match set is exact for every row a previous rule did
    # not touch. Rows whose mutable state changed (and synthetic transfer legs)
    # are the only ones re-evaluated in Ruby.
    def matching_ids(rule, stopped_ids)
      sql_ids = rule.matching_scope.pluck(:id).to_set
      ensure_loaded(sql_ids | overridden_ids | synthetic_ids)

      matched = sql_ids.dup
      (overridden_ids | synthetic_ids).each do |transaction_id|
        transaction = transactions_by_id[transaction_id]
        next unless transaction

        if in_effective_window?(transaction, rule) &&
           rule.conditions.all? { |condition| condition_matches?(transaction, condition) }
          matched << transaction_id
        else
          matched.delete(transaction_id)
        end
      end

      matched.reject { |transaction_id| stopped_ids.include?(transaction_id) }
    end

    # Loads only the ids a rule matched (or a previous rule changed), never the
    # whole family. Batched so a broad rule stays within one array bind.
    def ensure_loaded(transaction_ids)
      missing = transaction_ids.reject { |transaction_id| states.key?(transaction_id) }
      return if missing.empty?

      family.transactions
            .where("transactions.id = ANY(?::uuid[])", PG::TextEncoder::Array.new.encode(missing))
            .includes(:entry, :tags)
            .find_each do |transaction|
              transactions_by_id[transaction.id] = transaction
              states[transaction.id] = initial_state(transaction)
            end
    end

    def initial_state(transaction)
      {
        name: transaction.entry.name,
        category_id: transaction.category_id,
        merchant_id: transaction.merchant_id,
        tag_ids: transaction.tags.map(&:id),
        excluded: transaction.entry.excluded,
        investment_activity_label: transaction.investment_activity_label,
        kind: transaction.kind
      }
    end

    def in_effective_window?(transaction, rule)
      return true if rule.effective_date.blank?

      transaction.entry.date.present? && transaction.entry.date >= rule.effective_date
    end

    # Mirrors Rule::Condition's tree. Name/category/merchant/tag/type are
    # evaluated against the simulated state. Other leaves are row-level
    # predicates that rule updates cannot affect, so the existing filter query
    # supplies their ids; a synthetic transfer leg has no database row yet and
    # is evaluated entirely in Ruby.
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
        synthetic = synthetic_ids.include?(transaction.id)

        case condition.condition_type
        when "transaction_name"
          name_matches?(transaction, state[:name], condition.operator, condition.value)
        when "transaction_category"
          select_matches?(state[:category_id], condition.operator, condition.value)
        when "transaction_merchant"
          select_matches?(state[:merchant_id], condition.operator, condition.value)
        when "transaction_tag"
          tag_condition_matches?(state[:tag_ids], condition.operator, condition.value)
        when "transaction_type"
          transaction_type_matches?(transaction, state[:kind], condition.value)
        when "transaction_amount"
          synthetic ? amount_matches?(transaction, condition.operator, condition.value) : immutable_condition_ids(condition).include?(transaction.id)
        when "transaction_details"
          synthetic ? details_matches?(transaction, condition.operator) : immutable_condition_ids(condition).include?(transaction.id)
        when "transaction_notes"
          synthetic ? text_matches?(transaction.entry.notes, condition.operator, condition.value) : immutable_condition_ids(condition).include?(transaction.id)
        when "transaction_account"
          synthetic ? select_matches?(transaction.entry.account_id, condition.operator, condition.value) : immutable_condition_ids(condition).include?(transaction.id)
        else
          !synthetic && immutable_condition_ids(condition).include?(transaction.id)
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
      text_matches?(name, operator, value, transaction: transaction)
    end

    def text_matches?(text, operator, value, transaction: nil)
      normalized_text = normalize_text(text)
      normalized_value = normalize_text(value)

      case operator
      when "like"
        normalized_text.present? && normalized_text.downcase.include?(normalized_value.downcase)
      when "not_like"
        normalized_text.nil? || !normalized_text.downcase.include?(normalized_value.downcase)
      when "matches"
        normalized_text.present? && Regexp.new(value.to_s, Regexp::IGNORECASE).match?(normalized_text)
      when "not_matches"
        normalized_text.nil? || !Regexp.new(value.to_s, Regexp::IGNORECASE).match?(normalized_text)
      when "="
        if transaction
          plaid_name_equal?(transaction, normalized_text, normalized_value)
        else
          normalized_text == normalized_value
        end
      when "!="
        if transaction
          !plaid_name_equal?(transaction, normalized_text, normalized_value)
        else
          normalized_text != normalized_value
        end
      when "is_null"
        text.nil?
      when "is_not_null"
        !text.nil?
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

    def transaction_type_matches?(transaction, kind, value)
      amount = transaction.entry.amount

      case value
      when "income"
        amount.negative? && !Transaction::TRANSFER_KINDS.include?(kind)
      when "expense"
        !amount.negative? && !Transaction::TRANSFER_KINDS.include?(kind)
      when "transfer"
        Transaction::TRANSFER_KINDS.include?(kind)
      else
        false
      end
    end

    def amount_matches?(transaction, operator, value)
      amount = transaction.entry.amount.abs
      expected = value.to_d

      case operator
      when ">" then amount > expected
      when ">=" then amount >= expected
      when "<" then amount < expected
      when "<=" then amount <= expected
      when "=" then amount == expected
      when "!=" then amount != expected
      else false
      end
    end

    # Synthetic rows have no extra JSON yet; their only possible match is the
    # "is empty" operator.
    def details_matches?(transaction, operator)
      empty = transaction.extra.blank? || transaction.extra == {}
      operator == "is_null" && empty
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
      count = transfer_candidates(action, ids).size
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

    def transfer_candidates(action, ids)
      target_account = accounts_by_id[action.value]
      return [] if target_account.nil?

      ids.select do |transaction_id|
        state = states.fetch(transaction_id)
        next false if Transaction::TRANSFER_KINDS.include?(state[:kind])

        transactions_by_id.fetch(transaction_id).entry.account != target_account
      end
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

        ids.each { |transaction_id| set_state(transaction_id, :category_id, action.value) }
      when "set_transaction_merchant"
        return unless merchant_names.key?(action.value)

        ids.each { |transaction_id| set_state(transaction_id, :merchant_id, action.value) }
      when "set_transaction_name"
        return if action.value.blank?

        ids.each { |transaction_id| set_state(transaction_id, :name, action.value) }
      when "set_transaction_tags"
        tag_ids = valid_tag_ids(action.value)
        return if tag_ids.empty?

        ids.each do |transaction_id|
          set_state(transaction_id, :tag_ids, states.fetch(transaction_id)[:tag_ids] | tag_ids)
        end
      when "exclude_transaction"
        ids.each { |transaction_id| set_state(transaction_id, :excluded, true) }
      when "set_investment_activity_label"
        return unless Transaction::ACTIVITY_LABELS.include?(action.value)

        ids.each { |transaction_id| set_state(transaction_id, :investment_activity_label, action.value) }
      when "set_as_transfer_or_payment"
        apply_transfer_effect(action, ids)
      end
      # Async and notification actions do not change a matching attribute
      # synchronously.
    end

    def set_state(transaction_id, attribute, value)
      state = states.fetch(transaction_id)
      return if state[attribute] == value

      state[attribute] = value
      overridden_ids << transaction_id
    end

    # Mirrors SetAsTransferOrPayment: the matched transaction becomes one leg of
    # a confirmed transfer (its kind changes, and transfer validation can assign
    # a category), and a counter-leg is created on the target account. The
    # counter-leg is simulated in memory so lower rules can match it.
    def apply_transfer_effect(action, ids)
      target_account = accounts_by_id[action.value]
      return if target_account.nil?

      transfer_candidates(action, ids).each { |transaction_id| apply_transfer_to(transaction_id, target_account) }
    end

    def apply_transfer_to(transaction_id, target_account)
      transaction = transactions_by_id.fetch(transaction_id)
      source_account = transaction.entry.account
      amount = transaction.entry.amount
      original_is_outflow = amount.positive?

      to_account = original_is_outflow ? target_account : source_account
      from_account = original_is_outflow ? source_account : target_account
      outflow_kind = Transfer.kind_for_account(to_account, from_account: from_account)

      counter_state = {
        name: counter_transfer_name(transaction.entry, target_account),
        category_id: nil,
        merchant_id: nil,
        tag_ids: [],
        excluded: false,
        investment_activity_label: nil,
        kind: original_is_outflow ? "funds_movement" : outflow_kind
      }
      outflow_state = original_is_outflow ? states.fetch(transaction_id) : counter_state
      inflow_state = original_is_outflow ? counter_state : states.fetch(transaction_id)
      apply_transfer_categories(outflow_kind, to_account, outflow_state, inflow_state)

      set_state(transaction_id, :kind, original_is_outflow ? outflow_kind : "funds_movement")

      counter_id = SecureRandom.uuid
      counter_transaction = Transaction.new(
        id: counter_id,
        kind: counter_state[:kind],
        category_id: counter_state[:category_id],
        merchant_id: nil,
        investment_activity_label: nil,
        extra: {},
        locked_attributes: {}
      )
      counter_entry = Entry.new(
        account: target_account,
        amount: -amount,
        currency: transaction.entry.currency,
        date: transaction.entry.date,
        name: counter_state[:name],
        source: nil,
        excluded: false,
        user_modified: true
      )
      counter_entry.entryable = counter_transaction
      counter_transaction.entry = counter_entry

      transactions_by_id[counter_id] = counter_transaction
      states[counter_id] = counter_state
      synthetic_ids << counter_id if target_account.status.in?(Account::VISIBLE_STATUSES)
    end

    def counter_transfer_name(entry, target_account)
      prefix = target_account.liability? ? "Payment" : "Transfer"
      "#{prefix} #{entry.amount.negative? ? "to #{target_account.name}" : "from #{entry.account.name}"}"
    end

    # Transfer#confirm! only assigns a category when it already exists; the
    # preview must not create one, so a first-ever transfer of this kind leaves
    # the simulated category blank.
    def apply_transfer_categories(outflow_kind, to_account, outflow_state, inflow_state)
      if outflow_kind == "investment_contribution" && outflow_state[:category_id].blank?
        outflow_state[:category_id] = investment_contributions_category_id if investment_contributions_category_id.present?
      elsif outflow_kind == "cc_payment" && to_account.credit_card?
        category_id = credit_card_payment_category_id
        return if category_id.blank?

        outflow_state[:category_id] ||= category_id
        inflow_state[:category_id] ||= category_id
      end
    end

    def investment_contributions_category_id
      @investment_contributions_category_id
    end

    def credit_card_payment_category_id
      @credit_card_payment_category_id
    end

    def existing_category(names)
      family.categories.where(name: names).order(:created_at).pick(:id)
    end

    def existing_credit_card_payment_category
      names = LanguagesHelper::SUPPORTED_LOCALES.filter_map do |locale|
        I18n.t(Category::CREDIT_CARD_PAYMENT_NAME_KEY, locale: locale, default: nil).presence
      end.uniq
      existing_category(names)
    end
end
