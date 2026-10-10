# Pinned upstream mechanics this milestone's credit-envelope calculator is built on.
# Characterization tests only: each assertion must hold on the pin; a failure is the
# signal the mechanism differs and Task 3's query must change (see the plan's
# Interfaces -> Produces branch table).
#
# Confirmed on the m4ab-envelopes pin (M4a Task 8, 49122e53):
#
# 1. A credit account is an Account with `accountable_type = 'CreditCard'`, and its
#    generated `classification` column equals "liability".
#      app/models/concerns/accountable.rb:4   (CreditCard in Accountable::TYPES)
#      app/models/credit_card.rb:19-21        (class-level classification "liability")
#      db/schema.rb:105                       (virtual classification column -> liability)
#
# 2. A card payment is a Transfer whose destination is the card: the outflow (source)
#    leg carries `kind = "cc_payment"`, the inflow (card) leg is always
#    "funds_movement"; both kinds are in Transaction::BUDGET_EXCLUDED_KINDS, so both
#    legs are already excluded from budget spending.
#      app/models/transfer.rb:26-42           (kind_for_account: credit_card?/liability? -> cc_payment)
#      app/models/transfer.rb:106-110         (kind_for_leg: inflow leg always funds_movement)
#      app/models/transaction.rb:81,86        (TRANSFER_KINDS / BUDGET_EXCLUDED_KINDS)
#      app/models/income_statement/totals.rb:74,99 (both totals queries exclude those kinds)
#
# 3. Card spending is a POSITIVE entry amount (expenses are positive; income and
#    transfer inflows are negative), and it is a non-excluded "standard" kind.
#      app/models/income_statement/scoped_transactions_query.rb:13-18 (negative -> income, else expense)
#      test/models/income_statement_test.rb:19-20 (card purchases recorded as positive amounts)
#
# 4. Direction guard for payments: when card A pays card B, A's own outflow leg also
#    carries kind "cc_payment" (the kind derives from the DESTINATION) and its amount
#    is positive; B's receiving leg is "funds_movement" and negative. A payment query
#    must filter by the leg's account and direction, not by kind alone.
#      app/models/transfer.rb:26-42 + test 3 below
#
# 5. ExchangeRate.find_or_fetch_rate(from:, to:, date:) exists, is the fail-loud
#    conversion Budget::ReadyToAssign uses, and returns nil when no rate is available
#    (no configured provider / provider error), so the calculator's missing-rate
#    raise is reachable.
#      app/models/exchange_rate/provided.rb:14,29,33
#      app/models/budget.rb:544-547           (Budget#convert_to_budget_currency uses it)
require "test_helper"

class Budget::CreditEnvelopeMechanicsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "cc_payment and funds_movement are budget-excluded transfer kinds" do
    assert_includes Transaction::BUDGET_EXCLUDED_KINDS, "cc_payment"
    assert_includes Transaction::BUDGET_EXCLUDED_KINDS, "funds_movement"
    assert_includes Transaction::TRANSFER_KINDS, "cc_payment"
  end

  test "a transfer into a credit card puts cc_payment on the source leg and funds_movement on the card leg" do
    family = families(:empty)
    checking = family.accounts.create!(
      accountable: Depository.new, name: "Mechanics Checking",
      currency: "USD", balance: 1_000, status: "active"
    )
    card = family.accounts.create!(
      accountable: CreditCard.new, name: "Mechanics Card",
      currency: "USD", balance: 500, status: "active"
    )

    transfer = Transfer::Creator.new(
      family: family,
      source_account_id: checking.id,
      destination_account_id: card.id,
      date: Date.current,
      amount: 100
    ).create

    assert_equal "cc_payment", transfer.outflow_transaction.kind
    assert_equal "funds_movement", transfer.inflow_transaction.kind
    assert transfer.payment?, "a transfer whose destination is a liability is a payment"
    assert_equal "liability_payment", transfer.transfer_type
  end

  test "a card-to-card transfer puts a POSITIVE cc_payment leg on the paying card" do
    # The direction fact the calculator's payment query depends on: when card A
    # pays card B, A's own outflow leg also carries kind cc_payment (the kind is
    # derived from the DESTINATION being a credit card), and its amount is
    # positive — money leaving A, not a payment received. A query that summed
    # "cc_payment legs on this card" with no direction guard would draw A's
    # payment envelope down for a movement that grew A's debt.
    # Locals, not ivars: this class has no setup (Ruling P-m4b-2, 2026-10-10 pre-flight).
    family = families(:empty)
    card = family.accounts.create!(
      accountable: CreditCard.new, name: "Card A",
      currency: "USD", balance: 500, status: "active"
    )
    card_b = family.accounts.create!(
      accountable: CreditCard.new, name: "Card B",
      currency: "USD", balance: 0, status: "active"
    )
    Transfer::Creator.new(
      family: family, source_account_id: card.id, destination_account_id: card_b.id,
      date: Date.current, amount: 60
    ).create

    paying_leg = card.entries.order(:date).last
    receiving_leg = card_b.entries.order(:date).last

    assert_equal "cc_payment", paying_leg.entryable.kind
    assert_operator paying_leg.amount.to_d, :>, 0, "money leaving the card is positive"
    assert_equal "funds_movement", receiving_leg.entryable.kind
    assert_operator receiving_leg.amount.to_d, :<, 0, "money paid into the card is negative"
  end

  test "credit-card spending is a positive, non-excluded entry" do
    family = families(:empty)
    card = family.accounts.create!(
      accountable: CreditCard.new, name: "Mechanics Card 2",
      currency: "USD", balance: 0, status: "active"
    )
    category = family.categories.create!(name: "Mechanics Groceries")

    entry = create_transaction(account: card, amount: 60, category: category)

    assert_equal "standard", entry.entryable.kind
    assert_not_includes Transaction::BUDGET_EXCLUDED_KINDS, entry.entryable.kind
    assert_operator entry.amount, :>, 0, "a purchase is a positive entry, like every other expense"
  end

  test "a credit card is identified by accountable_type CreditCard and classifies as a liability" do
    family = families(:empty)
    card = family.accounts.create!(
      accountable: CreditCard.new, name: "Mechanics Card 3",
      currency: "USD", balance: 0, status: "active"
    )

    assert card.credit_card?
    assert_equal "CreditCard", card.accountable_type
    assert_equal "liability", card.classification
  end

  test "a missing exchange rate is reachable and returns nil" do
    assert_respond_to ExchangeRate, :find_or_fetch_rate
    assert_nil ExchangeRate.find_or_fetch_rate(from: "ZZZ", to: "USD", date: Date.current),
      "an unknown currency has no rate, so the calculator's raise is reachable"
  end
end
