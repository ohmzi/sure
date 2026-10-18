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
    # The hero's range toggle (the Alive pass, 2026-10-18).
    RANGES = { "1W" => "last_7_days", "1M" => "last_30_days", "1Y" => "last_365_days" }.freeze
    DEFAULT_RANGE = "1M"
    # The spending ring's slices: the biggest categories, the rest as one.
    SLICES = 5
    OTHER_COLOR = "#9E9E9E"

    Slice = Data.define(:name, :color, :amount)

    attr_reader :family, :user, :range

    def initialize(family:, user:, range: nil)
      @family = family
      @user = user
      @range = RANGES.key?(range) ? range : DEFAULT_RANGE
    end

    def net_worth_series
      @net_worth_series ||= family.balance_sheet(user: user).net_worth_series(period: Period.from_key(RANGES[range]))
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

    # This month's spending by category, largest first: the top SLICES, and
    # everything else as one "Other" slice.
    def spending_slices
      @spending_slices ||= begin
        slices = (budget&.budget_categories || []).reject(&:subcategory?).filter_map do |budget_category|
          amount = budget_category.actual_spending.to_d
          Slice.new(name: budget_category.name, color: budget_category.category.color.presence || OTHER_COLOR, amount:) if amount.positive?
        end.sort_by { |slice| -slice.amount }

        rest = slices.drop(SLICES).sum(&:amount)
        slices.first(SLICES).tap do |top|
          top << Slice.new(name: I18n.t("pages.dashboard.today.other"), color: OTHER_COLOR, amount: rest) if rest.positive?
        end
      end
    end

    def days_left_in_month = budget ? [ (budget.end_date - Date.current).to_i, 0 ].max : 0

    private
      def bills_scope
        family.recurring_transactions.accessible_by(user).bills.active
      end
  end
end
