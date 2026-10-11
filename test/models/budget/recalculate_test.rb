require "test_helper"

class Budget::RecalculateTest < ActiveSupport::TestCase
  test "delegates to the rollover calculator for the budget's owner" do
    family = families(:empty)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current)

    Budget::RolloverCalculator.any_instance.expects(:recompute!).once
    Budget::Recalculate.call(family: family, budget: budget)
  end

  # Ruling M4-L7 (2026-10-10 close-out): the seam owns every construction of
  # Budget::RolloverCalculator. A new direct caller outside it is how the fourth
  # legacy caller (the envelopes API's read refresh) escaped the suite, so the
  # callsite set is pinned here: any new file constructing the calculator fails
  # this test and must route through Budget::Recalculate instead. The assistant
  # writer (Assistant::Function::UpdateBudget) is accepted as scoped out of the
  # close-out; it never constructs this calculator, so it is not part of this
  # pin.
  test "only Budget::Recalculate constructs the rollover calculator" do
    callsites = %w[app lib].flat_map do |root|
      Dir[Rails.root.join(root, "**", "*.rb")].select do |path|
        File.read(path).match?(/RolloverCalculator\.new/)
      end
    end

    assert_equal [ Rails.root.join("app/models/budget/recalculate.rb").to_s ], callsites.sort,
      "a new direct Budget::RolloverCalculator caller must route through Budget::Recalculate"
  end
end
