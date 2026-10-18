# frozen_string_literal: true

# The week strip over Activity (the Alive pass, 2026-10-18): what went out on
# each of the last seven days, today last. Each day is the same expense total
# the Activity summary shows for that day, so the bars and the list agree.
class Transaction::Week
  DAYS = 7

  Day = Data.define(:date, :spent)

  def initialize(family:, accessible_account_ids:, today: Date.current)
    @family = family
    @accessible_account_ids = accessible_account_ids
    @today = today
  end

  def days
    @days ||= ((@today - (DAYS - 1))..@today).map do |date|
      day = date.iso8601
      totals = Transaction::Search.new(@family, filters: { "start_date" => day, "end_date" => day },
                                                accessible_account_ids: @accessible_account_ids).totals
      Day.new(date:, spent: totals.expense_money)
    end
  end

  def spent = days.map(&:spent).sum(Money.new(0, @family.currency))
end
