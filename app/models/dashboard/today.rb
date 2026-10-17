# frozen_string_literal: true

# The "Today" summary at the top of Home (the owner's redesign, 2026-10-17):
# one clear story before the customizable widgets — net worth and its line,
# what needs a person, what is left to spend this month, and the bills
# coming up. Each piece is computed on first use, so an empty family costs
# nothing it does not show.
module Dashboard
  class Today
    BILLS_WEEK = 7
    UPCOMING_WINDOW = 14
    UPCOMING_LIMIT = 3

    attr_reader :family, :user

    def initialize(family:, user:)
      @family = family
      @user = user
    end

    def net_worth_series
      @net_worth_series ||= family.balance_sheet(user: user).net_worth_series(period: Period.last_30_days)
    end

    # The line under the net worth: one number per day of the period.
    def net_worth_points
      @net_worth_points ||= net_worth_series.values.map do |point|
        value = point.value
        (value.respond_to?(:amount) ? value.amount : value).to_f
      end
    end

    def needs
      @needs ||= {
        documents: DocumentLink.needs_attention(family).count,
        uncategorized: Current.accessible_entries.uncategorized_transactions.count,
        bills: bills_scope.where(next_expected_date: Date.current..BILLS_WEEK.days.from_now.to_date).count
      }
    end

    def upcoming_bills
      @upcoming_bills ||= bills_scope
        .where(next_expected_date: Date.current..UPCOMING_WINDOW.days.from_now.to_date)
        .includes(:merchant)
        .order(:next_expected_date)
        .limit(UPCOMING_LIMIT)
        .to_a
    end

    def budget
      return @budget if defined?(@budget)

      @budget = Budget.find_or_bootstrap(family, start_date: Date.current, user: user)
    end

    def left_to_spend = budget&.available_to_spend

    # 0 until the month has a budget total (Budget#percent_of_budget_spent
    # does not guard an unset one).
    def percent_spent
      budgeted = budget&.budgeted_spending
      return 0 unless budgeted.to_d.positive?

      (budget.actual_spending.to_d / budgeted.to_d * 100).to_f.clamp(0, 100)
    end

    def days_left_in_month = budget ? [ (budget.end_date - Date.current).to_i, 0 ].max : 0

    private
      def bills_scope
        family.recurring_transactions.accessible_by(user).bills.active
      end
  end
end
