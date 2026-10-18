# Read-only preview of what an apply-all run would change.
#
# It mirrors Rule::Runner's matching, top-rule-wins claims and stop-processing
# handling, but answers with bulk GROUP BY queries instead of loading rows, so
# the confirmation screen can show a concrete before -> after summary without
# an N+1 for every matched transaction.
#
# Async actions (AI categorization/merchant detection) cannot be previewed row
# by row because they classify later in background jobs. They are reported as a
# count instead. Actions that create a transfer or send email change no stored
# attribute, so they are left out.
class Rule::ApplicationPreview
  Group = Struct.new(:from, :to, :count, keyword_init: true)
  Change = Struct.new(:rule, :action, :action_type, :total, :groups, keyword_init: true)

  def initialize(family)
    @family = family
    @category_names = family.categories.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @merchant_names = family.merchants.pluck(:id, :name).to_h { |id, name| [ id, name ] }
    @tag_names = family.tags.pluck(:id, :name).to_h { |id, name| [ id, name ] }
  end

  # Returns one Change per (rule, action) that would modify at least one
  # transaction, in rule and action order.
  def changes
    claimed_ids = Hash.new { |hash, attribute| hash[attribute] = Set.new }
    stopped_ids = Set.new
    result = []

    family.rules.ordered.includes(:actions, conditions: :sub_conditions).each do |rule|
      scope = Rule.excluding_transaction_ids(rule.matching_scope, stopped_ids)
      matched_ids = scope.pluck(:id)

      rule.actions.each do |action|
        excluded_ids = action_claim_attributes(action)
          .flat_map { |attribute| claimed_ids.fetch(attribute, []).to_a }
          .uniq
        action_scope = Rule.excluding_transaction_ids(scope, excluded_ids)

        change = build_change(rule, action, action_scope)
        result << change if change
      end

      rule.actions.each do |action|
        action_claim_attributes(action).each { |attribute| claimed_ids[attribute].merge(matched_ids) }
      end
      stopped_ids.merge(matched_ids) if rule.stop_processing?
    end

    result
  end

  private
    attr_reader :family, :category_names, :merchant_names, :tag_names

    def build_change(rule, action, scope)
      groups =
        case action.action_type
        when "set_transaction_category"
          category_groups(scope, action.value)
        when "set_transaction_merchant"
          merchant_groups(scope, action.value)
        when "set_transaction_name"
          name_groups(scope, action.value)
        when "set_transaction_tags"
          tag_groups(scope, action.value)
        when "exclude_transaction"
          excluded_groups(scope)
        when "set_investment_activity_label"
          investment_label_groups(scope, action.value)
        when "auto_categorize", "auto_detect_merchants"
          async_groups(scope, action.action_type)
        end

      return if groups.blank?

      Change.new(
        rule: rule,
        action: action,
        action_type: action.action_type,
        total: groups.sum(&:count),
        groups: groups.reject { |group| group.count.zero? }.sort_by { |group| -group.count }
      )
    end

    def category_groups(scope, value)
      return [] unless family.categories.exists?(id: value)

      counts = scope.where("transactions.category_id IS DISTINCT FROM ?", value)
                    .group("transactions.category_id")
                    .count
      counts.map { |id, count| Group.new(from: category_names[id], to: category_names[value], count: count) }
    end

    def merchant_groups(scope, value)
      return [] unless family.merchants.exists?(id: value)

      counts = scope.where("transactions.merchant_id IS DISTINCT FROM ?", value)
                    .group("transactions.merchant_id")
                    .count
      counts.map { |id, count| Group.new(from: merchant_names[id], to: merchant_names[value], count: count) }
    end

    def name_groups(scope, value)
      return [] if value.blank?

      counts = scope.where("entries.name IS DISTINCT FROM ?", value)
                    .group("entries.name")
                    .count
      counts.map { |name, count| Group.new(from: name, to: value, count: count) }
    end

    def tag_groups(scope, value)
      tag_ids = Rule::Action.decode_multi_value_names(value).filter_map { |id| tag_names.key?(id) ? id : nil }
      return [] if tag_ids.empty?

      # The executor adds every selected tag, so a transaction only escapes the
      # change when it already has all of them.
      with_all_tags = family.transactions
                            .select(:id)
                            .joins(:taggings)
                            .where(taggings: { tag_id: tag_ids })
                            .group("transactions.id")
                            .having("COUNT(DISTINCT taggings.tag_id) = ?", tag_ids.size)
      count = scope.where.not(id: with_all_tags).count
      return [] if count.zero?

      [ Group.new(from: nil, to: tag_ids.map { |id| tag_names[id] }.join(", "), count: count) ]
    end

    def excluded_groups(scope)
      count = scope.where("entries.excluded IS DISTINCT FROM TRUE").count
      return [] if count.zero?

      [ Group.new(from: false, to: true, count: count) ]
    end

    def investment_label_groups(scope, value)
      return [] unless Transaction::ACTIVITY_LABELS.include?(value)

      counts = scope.where("transactions.investment_activity_label IS DISTINCT FROM ?", value)
                    .group("transactions.investment_activity_label")
                    .count
      counts.map { |label, count| Group.new(from: label, to: value, count: count) }
    end

    def async_groups(scope, action_type)
      attribute = action_type == "auto_categorize" ? :category_id : :merchant_id
      count = scope.enrichable(attribute).count
      return [] if count.zero?

      [ Group.new(from: nil, to: nil, count: count) ]
    end

    # Same shape as Rule::Runner#reserved_attributes, including its tolerance
    # for an action type this rule can no longer resolve.
    def action_claim_attributes(action)
      return [] unless action.reserves_claimed_attributes?

      action.claimed_attributes
    rescue => e
      Rails.logger.warn("Rule::ApplicationPreview could not read claims of action #{action.id}: #{e.class}: #{e.message}")
      []
    end
end
