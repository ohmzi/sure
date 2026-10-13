require "test_helper"

class Account::DocumentMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @chequing = accounts(:depository)
    @card = accounts(:credit_card)
    @chequing.update!(institution_name: "Chase", last4: "1234")
    @card.update!(institution_name: "Chase", account_network: "visa", last4: "4242")
  end

  test "a last4 match picks the card, not the account at the same bank" do
    match = Account::DocumentMatcher.best_match(
      family: @family, institution_hint: "Chase", account_last4_hint: "4242", last4_witness: true
    )

    assert_equal @card.id, match.account.id
  end

  test "the network only breaks a tie it can actually break" do
    match = Account::DocumentMatcher.best_match(family: @family, card_network: "visa", institution_hint: "Chase")

    assert_equal @card.id, match.account.id
  end

  test "no hints at all is nil, never the first account" do
    assert_nil Account::DocumentMatcher.best_match(family: @family)
  end

  test "two accounts the hints cannot tell apart resolve to nil rather than a coin flip" do
    @chequing.update!(institution_name: "Bank", last4: "9999")
    @card.update!(institution_name: "Bank")

    assert_nil Account::DocumentMatcher.best_match(family: @family, institution_hint: "Bank")
  end

  test "a wrong last4 does not resolve" do
    match = Account::DocumentMatcher.best_match(family: @family, account_last4_hint: "8888")

    assert_nil match
  end

  test "the auto bar is above the minimum floor" do
    assert_operator Account::DocumentMatcher::AUTO_PREFILL_BAR, :>, Account::DocumentMatcher::MINIMUM_CONFIDENCE
  end

  # --- The OCR second witness (spec §7.5) -------------------------------------

  test "a last4 match backed by the OCR witness clears the auto bar on its own" do
    # The read gave card_last4 "4242" and the page text contains it. With no
    # institution to lean on, the witnessed last4 must be able to prefill.
    match = Account::DocumentMatcher.best_match(
      family: @family, account_last4_hint: "4242", last4_witness: true
    )

    assert_equal @card.id, match.account.id
    assert_operator match.confidence, :>=, Account::DocumentMatcher::AUTO_PREFILL_BAR
  end

  test "an unwitnessed last4 contributes nothing, so it never resolves on its own" do
    # The witness is a GATE, not a bonus: a validly-typed last4 the OCR text does
    # not carry scores zero for the last4 term. On its own (no institution) that
    # is below the floor, so it cannot even resolve — let alone prefill.
    assert_nil Account::DocumentMatcher.best_match(
      family: @family, account_last4_hint: "4242"
    )
  end

  test "an unwitnessed last4 does not lift a matching institution to the bar" do
    # institution (0.35) + an unwitnessed last4 (0) + currency (0.05) = 0.40:
    # above the floor, below the bar. The wrong-but-validly-typed digit the page
    # never carried must not push a prefill. The other account is left off the
    # institution so this is not a tie.
    @chequing.update!(institution_name: nil)
    match = Account::DocumentMatcher.best_match(
      family: @family, institution_hint: "Chase", account_last4_hint: "4242", currency: "USD"
    )

    assert_operator match.confidence, :<, Account::DocumentMatcher::AUTO_PREFILL_BAR
  end

  test "a witnessed last4 does not resolve two accounts that share it" do
    @chequing.update!(institution_name: "Chase", last4: "4242")

    assert_nil Account::DocumentMatcher.best_match(
      family: @family, account_last4_hint: "4242", last4_witness: true
    )
  end
end
