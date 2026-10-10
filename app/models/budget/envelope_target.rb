# A per-envelope funding goal. Preferences (type) travel forward like the
# rollover toggle; amounts are recomputed from the envelope's current money,
# so nothing here is stored derived state.
class Budget::EnvelopeTarget
  def self.monthly_required(budget_category)
    new(budget_category).monthly_required
  end

  def initialize(budget_category)
    @budget_category = budget_category
  end

  # nil when the envelope has no target.
  def monthly_required
    return nil if budget_category.target_type.blank? || budget_category.target_amount.nil?
    return 0.to_d if funded?

    case budget_category.target_type
    when "monthly_assign"     then target_amount
    when "savings_balance",
         "needed_for_spending" then gap
    when "savings_by_date"    then gap / months_left
    else 0.to_d
    end
  end

  def funded?
    budget_category.available_to_spend.to_d >= target_amount.to_d
  end

  def remaining
    return nil if budget_category.target_type.blank?

    [ target_amount.to_d - budget_category.available_to_spend.to_d, 0.to_d ].max
  end

  private
    attr_reader :budget_category

    def target_amount = budget_category.target_amount.to_d

    def gap = remaining

    def months_left
      start = budget_category.budget.start_date
      finish = budget_category.target_date || start
      months = (finish.year * 12 + finish.month) - (start.year * 12 + start.month)
      [ months, 1 ].max
    end
end
