require "test_helper"

class Budget::EnvelopeTargetTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @category = @family.categories.create!(name: "Vacations", color: "#6172F3")
    @account = @family.accounts.create!(
      accountable: Depository.new, name: "Checking", currency: "USD",
      balance: 0, status: "active"
    )
    @budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    @budget.update!(budgeted_spending: 5_000)
    @bc = @budget.budget_categories.find_by!(category: @category)
  end

  test "returns nil without a target" do
    assert_nil Budget::EnvelopeTarget.monthly_required(@bc)
  end

  test "monthly_assign needs the full amount each month" do
    @bc.update!(target_type: "monthly_assign", target_amount: 300)
    assert_equal 300, Budget::EnvelopeTarget.monthly_required(@bc)
  end

  test "savings_balance asks for the gap to the target" do
    @bc.update!(target_type: "savings_balance", target_amount: 1000, budgeted_spending: 400)
    assert_equal 600, Budget::EnvelopeTarget.monthly_required(@bc)
  end

  test "savings_by_date spreads the gap across the months left" do
    @bc.update!(target_type: "savings_by_date", target_amount: 900, budgeted_spending: 0,
                target_date: @budget.start_date + 3.months)
    target = Budget::EnvelopeTarget.new(@bc)
    assert_equal 300, target.monthly_required
    assert_not target.funded?
  end

  test "is funded once the envelope holds the target" do
    @bc.update!(target_type: "savings_balance", target_amount: 500, budgeted_spending: 500)
    target = Budget::EnvelopeTarget.new(@bc)
    assert target.funded?
    assert_equal 0, target.monthly_required
  end
end
