require "test_helper"

class CreditCardPaymentsComponentTest < ViewComponent::TestCase
  setup do
    @family = families(:empty)
    @budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    @card = @family.accounts.create!(
      accountable: CreditCard.new, name: "Rewards", currency: "USD", balance: 250, status: "active"
    )
    CreditEnvelope.create!(
      budget: @budget, account: @card, funded_amount: 100, payment_amount: 40, currency: "USD"
    )
  end

  test "renders funded, paid and remaining to pay for each card" do
    render_inline(CreditCardPaymentsComponent.new(budget: @budget))

    assert_text I18n.t("budgets.credit_card_payments.title")
    assert_text "Rewards"
    assert_text "100.00" # funded
    assert_text "40.00"  # paid
    assert_text "60.00"  # remaining to pay
  end

  test "shows the amount needed to pay the cards in full" do
    render_inline(CreditCardPaymentsComponent.new(budget: @budget))

    # 250 debt - 60 already set aside = 190 still to fund.
    assert_text "190.00"
  end
end
