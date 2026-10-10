# The single place the envelope chain is recomputed after a money write. Today
# it runs only the rollover calculator; M4b extends this one class to also run
# Budget::CreditEnvelopeCalculator, so every write path keeps calling this seam
# and never a calculator directly.
module Budget::Recalculate
  def self.call(family:, budget:)
    Budget::RolloverCalculator.new(family: family, user: budget.user).recompute!
  end
end
