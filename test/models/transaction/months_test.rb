require "test_helper"

# The month bars over Activity (the owner, 2026-10-18; days before that): what
# went out in each of the last six months, this month last, each a tap away
# from that month's list.
class Transaction::MonthsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @today = Date.new(2026, 10, 18)
  end

  def months = Transaction::Months.new(family: @family, accessible_account_ids: @family.accounts.pluck(:id), today: @today)

  test "has the last six months, this one last, each a whole month" do
    list = months.months

    assert_equal 6, list.size
    assert_equal Date.new(2026, 5, 1), list.first.start_date
    assert_equal Date.new(2026, 10, 1), list.last.start_date
    assert_equal Date.new(2026, 10, 31), list.last.end_date
  end

  test "counts what went out in a month and leaves income out" do
    create_transaction(account: @account, date: Date.new(2026, 8, 12), amount: 40, currency: @family.currency)
    create_transaction(account: @account, date: Date.new(2026, 8, 20), amount: -500, currency: @family.currency)

    august = months.months.find { |month| month.start_date == Date.new(2026, 8, 1) }

    assert_operator august.spent.amount, :>=, 40
    assert_equal months.months.sum { |month| month.spent.amount }, months.spent.amount
  end
end
