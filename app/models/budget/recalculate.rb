# The single recompute seam for a budget's derived state. Every write path that
# can change an allocation -- or bootstrap a month -- calls this, never the
# calculators directly, so the lock order is fixed in one place: the rollover
# chain first, the credit-envelope chain second.
module Budget::Recalculate
  def self.call(family:, budget:)
    Budget::RolloverCalculator.new(family: family, user: budget.user).recompute!
    # After the rollover, never before: this calculator reads the carry the
    # rollover just materialized and then takes its own advisory lock, so the
    # lock order (rollover, then credit) has to hold at every trigger.
    Budget::CreditEnvelopeCalculator.new(family: family, budget: budget).recompute!
    nil
  end
end
