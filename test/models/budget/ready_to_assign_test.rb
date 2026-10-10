require "test_helper"

class Budget::ReadyToAssignTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @salary = @family.categories.create!(name: "Salary", color: "#22c55e")
    @home = @family.categories.create!(name: "Home", color: "#6172F3")
    @repairs = @family.categories.create!(name: "Repairs", parent: @home, color: "#6172F3")
    @account = @family.accounts.create!(
      accountable: Depository.new, name: "Checking", currency: "USD",
      balance: 0, status: "active"
    )
  end

  test "assigned counts a parent-with-ring-fenced-child exactly once" do
    budget = initialized_budget(Date.current)
    parent_bc = budget.budget_categories.find_by!(category: @home)
    child_bc  = budget.budget_categories.find_by!(category: @repairs)

    # Parent's stored figure already contains the child's. A naive sum over
    # both would read 900 and overstate what the user has assigned.
    parent_bc.update!(budgeted_spending: 500)
    child_bc.update!(budgeted_spending: 400)

    assert_equal 500, Budget::ReadyToAssign.new(family: @family, budget: budget).assigned
  end

  test "assigned accumulates across the chain up to and including the month" do
    first = initialized_budget(2.months.ago)
    first.budget_categories.find_by!(category: @home).update!(budgeted_spending: 100)

    second = initialized_budget(1.month.ago)
    second.budget_categories.find_by!(category: @home).update!(budgeted_spending: 200)

    assert_equal 300, Budget::ReadyToAssign.new(family: @family, budget: second).assigned
  end

  test "income counts only income-category entries on reportable accounts" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    create_transaction(account: @account, date: budget.start_date, amount: 50, category: @home)

    assert_equal 2000, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  test "income excludes transfers and cc_payment rows" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    create_transaction(account: @account, date: budget.start_date, amount: -500, category: @salary, kind: "cc_payment")
    create_transaction(account: @account, date: budget.start_date, amount: -300, category: @salary, kind: "funds_movement")

    assert_equal 2000, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  test "amount is income minus assigned through the month" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    budget.budget_categories.find_by!(category: @home).update!(budgeted_spending: 500)

    assert_equal 1500, Budget::ReadyToAssign.new(family: @family, budget: budget).amount
  end

  test "raises when an income entry has no exchange rate into the budget currency" do
    @family.update!(currency: "USD")
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -100,
                       currency: "JPY", category: @salary)

    # Stub the rate lookup so the test never depends on seeded rates or the
    # network; a missing rate must raise, not silently convert 1:1.
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_raises(Budget::ReadyToAssign::MissingExchangeRate) do
      Budget::ReadyToAssign.new(family: @family, budget: budget).income
    end
  end

  test "converts a foreign income entry through the stored exchange rate" do
    @family.update!(currency: "USD")
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -100,
                       currency: "EUR", category: @salary)
    # A stored row is found by exact (from, to, date), so no provider call is
    # made; the rate multiplies the raw entry amount, pinning the direction.
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD",
                         date: budget.start_date, rate: 1.25)

    assert_equal 125, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  private
    def initialized_budget(date)
      Budget.find_or_bootstrap(@family, start_date: date).tap do |budget|
        budget.update!(budgeted_spending: 5_000)
      end
    end
end
