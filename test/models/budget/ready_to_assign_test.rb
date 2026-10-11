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

  # Ruling M4-L1 (2026-10-10 close-out): RTA(month) is cumulative -- income
  # through the viewed month's end minus every chain month's assignments. The
  # pinned halves above each exercise one side alone; this combines them, the
  # case the period-scoped income read got wrong from the second chain month.
  test "RTA carries income from earlier months in the chain minus every month's assignments" do
    first = initialized_budget(2.months.ago)
    create_transaction(account: @account, date: first.start_date, amount: -2000, category: @salary)
    first.budget_categories.find_by!(category: @home).update!(budgeted_spending: 100)

    second = initialized_budget(1.month.ago)
    create_transaction(account: @account, date: second.start_date, amount: -500, category: @salary)
    second.budget_categories.find_by!(category: @home).update!(budgeted_spending: 200)

    rta = Budget::ReadyToAssign.new(family: @family, budget: second)

    assert_equal 2500, rta.income, "income through the viewed month is cumulative"
    assert_equal 300, rta.assigned, "every chain month's assignments count"
    assert_equal 2200, rta.amount, "one month's income minus every month's assignments was the defect"
  end

  # The mirror case: the cumulative window starts at the chain's own first
  # budget month, so history before the family ever opened a budget cannot
  # inflate RTA (Ruling M4-L1, 2026-10-10 close-out).
  test "income excludes entries before the chain's first budget month" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    create_transaction(account: @account, date: budget.start_date - 1.day, amount: -900, category: @salary)

    assert_equal 2000, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  test "income counts only income-category entries on reportable accounts" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    create_transaction(account: @account, date: budget.start_date, amount: 50, category: @home)

    assert_equal 2000, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  test "income excludes every transfer kind (Ruling M4a-L1)" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    Transaction::TRANSFER_KINDS.each do |kind|
      create_transaction(account: @account, date: budget.start_date, amount: -500, category: @salary, kind: kind)
    end

    assert_equal 2000, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  test "income counts a one_time entry that is categorized as income (Ruling M4a-L1)" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    create_transaction(account: @account, date: budget.start_date, amount: -1250, category: @salary, kind: "one_time")

    assert_equal 3250, Budget::ReadyToAssign.new(family: @family, budget: budget).income
  end

  test "income excludes provider-pending entries (Ruling M4a-L1)" do
    budget = initialized_budget(Date.current)
    create_transaction(account: @account, date: budget.start_date, amount: -2000, category: @salary)
    # Mechanical correction to the amended plan's test line: `extra` is a
    # `transactions` column, not an entries column, so it cannot ride through
    # `create_transaction` (UnknownAttributeError for Entry). This is the same
    # create-then-update idiom the repo's other pending fixtures use.
    pending_entry = create_transaction(account: @account, date: budget.start_date, amount: -700, category: @salary)
    pending_entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

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
