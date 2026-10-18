# frozen_string_literal: true

# The month bars over Activity (the owner, 2026-10-18; days before that): what
# went out in each of the last six months, this month last. Each month is the
# same expense total the Activity summary shows for that month, so a bar and
# the list it opens agree.
class Transaction::Months
  COUNT = 6

  Month = Data.define(:start_date, :end_date, :spent)

  def initialize(family:, accessible_account_ids:, today: Date.current)
    @family = family
    @accessible_account_ids = accessible_account_ids
    @today = today
  end

  def months
    @months ||= (COUNT - 1).downto(0).map do |back|
      start_date = @today.beginning_of_month << back
      end_date = start_date.end_of_month
      totals = Transaction::Search.new(@family, filters: { "start_date" => start_date.iso8601, "end_date" => end_date.iso8601 },
                                                accessible_account_ids: @accessible_account_ids).totals
      Month.new(start_date:, end_date:, spent: totals.expense_money)
    end
  end

  def spent = months.map(&:spent).sum(Money.new(0, @family.currency))
end
