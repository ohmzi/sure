require "test_helper"

class Budget::RecalculateTest < ActiveSupport::TestCase
  test "delegates to the rollover calculator for the budget's owner" do
    family = families(:empty)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current)

    Budget::RolloverCalculator.any_instance.expects(:recompute!).once
    Budget::Recalculate.call(family: family, budget: budget)
  end
end
