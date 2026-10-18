require "test_helper"

# The week strip over Activity (the Alive pass, 2026-10-18): what went out on
# each of the last seven days, today last.
class Transaction::WeekTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @today = Date.new(2026, 10, 18)
  end

  def week = Transaction::Week.new(family: @family, accessible_account_ids: @family.accounts.pluck(:id), today: @today)

  test "has the last seven days, today last" do
    days = week.days

    assert_equal 7, days.size
    assert_equal @today - 6, days.first.date
    assert_equal @today, days.last.date
  end

  test "counts what went out on a day and leaves income out" do
    create_transaction(account: @account, date: @today - 2, amount: 40, currency: @family.currency)
    create_transaction(account: @account, date: @today - 2, amount: -500, currency: @family.currency)

    day = week.days.find { |d| d.date == @today - 2 }

    assert_operator day.spent.amount, :>=, 40
    assert_equal week.days.sum { |d| d.spent.amount }, week.spent.amount
  end
end
