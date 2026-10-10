# Materialized credit-card payment envelope for one (budget month, credit
# account). Written only by Budget::CreditEnvelopeCalculator; never derived on
# read and never written by the entry path (D8).
class CreditEnvelope < ApplicationRecord
  # Ruling M4b-L2: a card whose currency differs from the budget's must be
  # converted, and a missing rate must fail loudly — the same rule
  # Budget::ReadyToAssign and Budget::CreditEnvelopeCalculator follow
  # (spec §13: the envelope money path never falls back to 1:1). Declared here
  # so Task 2's model does not depend on Task 3's calculator class.
  class MissingExchangeRate < StandardError; end

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
  # Ruling M4b-L2: account.balance is in the CARD's currency while
  # payment_available is in the budget's — a raw subtraction would put a
  # mixed-unit figure on the milestone's primary surface.
  def shortfall_to_pay_in_full
    [ converted_balance - payment_available, 0 ].max
  end

  private

    def converted_balance
      return account.balance.to_d if account.currency == currency

      rate = ExchangeRate.find_or_fetch_rate(from: account.currency, to: currency, date: Date.current)&.rate
      raise MissingExchangeRate, "no #{account.currency}->#{currency} rate for the credit envelope" if rate.nil?

      account.balance.to_d * rate
    end
end
