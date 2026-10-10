# Materialized credit-card payment envelope for one (budget month, credit
# account). Written only by Budget::CreditEnvelopeCalculator; never derived on
# read and never written by the entry path (D8).
class CreditEnvelope < ApplicationRecord
  include Monetizable

  belongs_to :budget
  belongs_to :account

  validates :budget_id, uniqueness: { scope: :account_id }
  validates :currency, presence: true

  # Cumulative funded card spending moved onto the payment envelope, and the
  # cumulative payments that drew it down. Both in `currency`.
  monetize :funded_amount, :payment_amount, :payment_available, :shortfall_to_pay_in_full

  # What is set aside and not yet paid out: the balance of the payment envelope.
  def payment_available
    funded_amount - payment_amount
  end

  # The card's current debt (a liability balance is positive) that the payment
  # envelope does not yet cover: what the user would still assign to be able to
  # pay this card in full. Floored at zero, since an over-funded envelope needs
  # nothing more.
  def shortfall_to_pay_in_full
    [ account.balance - payment_available, 0 ].max
  end
end
