# frozen_string_literal: true

# The credit-card payments group of the envelope surface: one row per credit
# card showing the money moved onto its payment envelope (Funded), the payments
# that drew it down (Paid), what is left set aside (Remaining to pay), and the
# total still needed to cover every card in full. Reads the materialized rows
# written by Budget::CreditEnvelopeCalculator. Renders nothing when the budget
# has no envelope rows.
class CreditCardPaymentsComponent < ViewComponent::Base
  attr_reader :budget

  def initialize(budget:)
    @budget = budget
  end

  def envelopes
    @envelopes ||= budget.credit_envelopes.includes(:account).to_a
                        .sort_by { |envelope| envelope.account.name }
  end

  # The amount the user would still assign so every card's payment envelope
  # covers its current debt in full.
  def shortfall_total_money
    Money.new(envelopes.sum(BigDecimal("0")) { |e| e.shortfall_to_pay_in_full }, budget.currency)
  end

  def render?
    envelopes.any?
  end
end
