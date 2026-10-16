require "test_helper"

class AccountStatement::AccountMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @card = accounts(:credit_card)
    @depository = accounts(:depository)
  end

  test "a seeded account last4 yields a suggestion even when the institution prose disagrees" do
    # The live statement read: institution "Your Triangle", account_last4 "7512".
    # The account's last4 is the seeded identity; the name/institution prose never
    # contains it, so before the column read this scored zero and the statement
    # sat unmatched with no suggestion.
    @card.update!(institution_name: "Triangle", last4: "7512")

    statement = AccountStatement.new(
      family: @family,
      institution_name_hint: "Your Triangle",
      account_last4_hint: "7512",
      currency: @card.currency
    )

    match = AccountStatement::AccountMatcher.new(statement).best_match

    assert_equal @card, match.account
  end

  test "a last4 that matches no seeded account does not resolve" do
    @card.update!(last4: "7512")

    statement = AccountStatement.new(
      family: @family,
      account_last4_hint: "7891",
      currency: @card.currency
    )

    assert_nil AccountStatement::AccountMatcher.new(statement).best_match
  end

  test "the account network breaks a tie the last4 leaves open" do
    # Two cards at the same bank with no seeded last4: the network hint is the
    # only signal that can tell them apart, read from the accounts.account_network
    # column (never a substring of the prose).
    @depository.update!(institution_name: "Triangle", last4: nil)
    @card.update!(institution_name: "Triangle", last4: nil, account_network: "mastercard")

    match = AccountStatement::AccountMatcher.best_match(
      family: @family, institution_hint: "Triangle", card_network: "mastercard"
    )

    assert_equal @card, match.account
  end

  test "two accounts the hints cannot tell apart resolve to nil, never a coin flip" do
    @depository.update!(institution_name: "Triangle", last4: nil, account_network: "mastercard")
    @card.update!(institution_name: "Triangle", last4: nil, account_network: "mastercard")

    assert_nil AccountStatement::AccountMatcher.best_match(
      family: @family, institution_hint: "Triangle", card_network: "mastercard"
    )
  end

  # The owner's June statement: issuer "Canadian Tire Bank", account
  # "Canadian Tire Mastercard", a reissued card number — no suggestion at all.
  test "a June-shaped statement is suggested its card account" do
    @card.update!(name: "Canadian Tire Mastercard", institution_name: nil, last4: nil)
    @depository.update!(institution_name: nil)

    match = AccountStatement::AccountMatcher.best_match(
      family: @family, institution_hint: "Canadian Tire Bank", account_last4_hint: "1512"
    )

    assert_equal @card, match&.account
  end

  test "a card number the account carried on an earlier statement scores like its own" do
    @card.update!(last4: "3111")
    @card.stubs(:known_card_last4s).returns(%w[3111 1512])

    assert AccountStatement::AccountMatcher.send(:last4_column_matches?, @card, "1512")
  end
end
