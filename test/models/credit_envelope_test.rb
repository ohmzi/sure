require "test_helper"

class CreditEnvelopeTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    @card = @family.accounts.create!(
      accountable: CreditCard.new, name: "Envelope Card",
      currency: "USD", balance: 250, status: "active"
    )
  end

  test "payment_available is funded minus paid" do
    envelope = CreditEnvelope.create!(
      budget: @budget, account: @card, funded_amount: 100, payment_amount: 30, currency: "USD"
    )

    assert_equal 70, envelope.payment_available.to_d
    assert_equal Money.new(70, "USD"), envelope.payment_available_money
  end

  test "shortfall to pay in full is the card debt not yet set aside" do
    envelope = CreditEnvelope.create!(
      budget: @budget, account: @card, funded_amount: 100, payment_amount: 40, currency: "USD"
    )

    assert_equal 190, envelope.shortfall_to_pay_in_full.to_d # 250 debt - 60 available
  end

  test "shortfall never goes negative when the envelope exceeds the debt" do
    envelope = CreditEnvelope.create!(
      budget: @budget, account: @card, funded_amount: 300, payment_amount: 0, currency: "USD"
    )

    assert_equal 0, envelope.shortfall_to_pay_in_full.to_d
  end

  test "one row per budget and account" do
    CreditEnvelope.create!(budget: @budget, account: @card, currency: "USD")

    duplicate = CreditEnvelope.new(budget: @budget, account: @card, currency: "USD")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:budget_id], "has already been taken"
  end
end
