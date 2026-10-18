require "test_helper"

# The "Today" summary at the top of Home (the owner's redesign, 2026-10-17):
# net worth with its line, what needs a person, what is left to spend this
# month, and the bills coming up.
class Dashboard::TodayTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    Current.session = @user.sessions.create!
  end

  teardown { Current.reset }

  def today = Dashboard::Today.new(family: @family, user: @user)

  test "counts what needs a person: documents, uncategorized transactions, bills due this week" do
    counts = today.needs

    assert_equal DocumentLink.needs_attention(@family).count, counts[:documents]
    assert_equal Current.accessible_entries.uncategorized_transactions.count, counts[:uncategorized]
    assert_kind_of Integer, counts[:bills]
  end

  test "a bill due within the week counts, and shows in the coming-up list" do
    bill = @family.recurring_transactions.create!(
      name: "Hydro", amount: 137.71, currency: @family.currency,
      expected_day_of_month: 21, next_expected_date: 3.days.from_now.to_date, last_occurrence_date: 27.days.ago.to_date
    )

    assert_operator today.needs[:bills], :>=, 1
    assert_includes today.upcoming_bills.map(&:id), bill.id
  end

  test "the net worth line has one point per day of the period" do
    points = today.net_worth_points

    assert points.all? { |point| point.is_a?(Numeric) }
  end

  test "left to spend reads the current month's budget" do
    budget = today.budget
    skip "no budget for this family's current month" if budget.nil?

    assert_equal budget.available_to_spend, today.left_to_spend
    assert_operator today.days_left_in_month, :>=, 0
  end

  test "a month with no budget total reads as nothing spent rather than failing" do
    budget = today.budget
    skip "no budget for this family's current month" if budget.nil?
    budget.update_columns(budgeted_spending: nil)

    assert_equal 0, Dashboard::Today.new(family: @family, user: @user).percent_spent
  end

  # The hero's range (the Alive pass, 2026-10-18): a week, a month or a year of
  # net worth; anything else reads as the month.
  test "the net worth range picks its period and falls back to the month" do
    assert_equal "1Y", Dashboard::Today.new(family: @family, user: @user, range: "1Y").range
    assert_equal Period.from_key("last_365_days").start_date,
                 Dashboard::Today.new(family: @family, user: @user, range: "1Y").net_worth_series.start_date
    assert_equal "1M", Dashboard::Today.new(family: @family, user: @user, range: "bogus").range
  end

  # The ring under "left to spend" (the Alive pass): each spending category is
  # its own coloured slice, largest first, the rest gathered into one.
  test "spending slices are the month's categories with spending, largest first" do
    budget = today.budget
    skip "no budget for this family's current month" if budget.nil?

    slices = today.spending_slices

    assert slices.all? { |slice| slice.amount.positive? }
    assert_equal slices.map(&:amount).sort.reverse, slices.map(&:amount)
    assert_operator slices.size, :<=, Dashboard::Today::SLICES + 1
    assert slices.all? { |slice| slice.color.present? && slice.name.present? }
  end
end
