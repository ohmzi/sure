require "test_helper"

# The statement's identity, read from its own text layer: what the model used
# to be asked for (and got wrong — a Mastercard read as "amex") is printed on
# the page, so it is parsed, not guessed.
class StatementRead::IdentityTest < ActiveSupport::TestCase
  TEXT = <<~TEXT
    Your Triangle Mastercard Statement
    Statement date: June 8, 2026
    For the period: May 9, 2026 to June 8, 2026
    Account number: 5446 12XX XXXX 1512
    Purchases - Card #5446 12XX XXXX 1512
     Total purchases for 5446 12XX XXXX 1512                 $8,091.96
    Purchases - Card #5446 12XX XXXX 8555
     Total purchases for 5446 12XX XXXX 8555                    $96.05
    The Triangle Mastercard is issued by Canadian Tire Bank.
  TEXT

  def identity(text = TEXT) = StatementRead::Identity.call(text)

  test "reads the account number's last four" do
    assert_equal "1512", identity.account_last4
  end

  test "lists every card the statement carries, in order, once each" do
    assert_equal %w[1512 8555], identity.card_last4s
  end

  test "decides the network from the card number's prefix" do
    assert_equal "mastercard", identity.card_network
    assert_equal "visa", identity("Account number: 4111 11XX XXXX 0004").card_network
    assert_equal "amex", identity("Account number: 3712 34XXXX X1005").card_network
    assert_equal "mastercard", identity("Account number: 2221 00XX XXXX 0009").card_network
  end

  test "falls back to a single network named in the text when the number has no usable prefix" do
    fully_masked = identity("Your Visa statement\nAccount number: XXXX XXXX XXXX 1234")
    assert_equal "visa", fully_masked.card_network
    assert_equal "1234", fully_masked.account_last4
    assert_nil identity("Pay with Visa or Mastercard\nAccount number: XXXX XXXX XXXX 1234").card_network
  end

  test "reads the issuing institution" do
    assert_equal "Canadian Tire Bank", identity.institution_name
  end

  # The layout text puts two columns on one line, so the sentence runs straight
  # into the next column's words (seen on the real June statement).
  test "stops the institution at the end of its sentence" do
    glued = "The Triangle Mastercard is issued by Canadian Tire Bank. May 9   Your Payment"

    assert_equal "Canadian Tire Bank", identity(glued).institution_name
  end

  test "reads the statement period" do
    assert_equal Date.new(2026, 5, 9), identity.period_start
    assert_equal Date.new(2026, 6, 8), identity.period_end
  end

  test "is complete only when account, network, institution and period are all present" do
    assert identity.complete?
    assert_not identity(TEXT.sub(/^Account number:.*$/, "")).complete?
    assert_not identity(TEXT.sub(/^The Triangle.*$/, "")).complete?
  end

  # A chequing account has no card and so no network; requiring one would send
  # every chequing statement to the model for a field that cannot exist.
  test "an identity with no card is complete without a network" do
    no_card = StatementRead::Identity::Result.new(
      institution_name: "Royal Bank of Canada", account_last4: "6719", card_last4s: [], card_network: nil,
      period_start: Date.new(2026, 9, 11), period_end: Date.new(2026, 10, 9)
    )

    assert no_card.complete?
    assert_not no_card.with(card_last4s: [ "1512" ]).complete?, "a card statement still needs its network"
  end

  test "maps onto the understanding's verdict fields" do
    fields = identity.to_verdict_fields

    assert_equal "statement", fields["document_class"]
    assert_equal "1512", fields["account_last4"]
    assert_equal "1512", fields["card_last4"]
    assert_equal "mastercard", fields["card_network"]
    assert_equal "Canadian Tire Bank", fields["institution_name"]
    assert_equal({ "start" => "2026-05-09", "end" => "2026-06-08" }, fields["statement_period"])
  end

  test "an empty text has no identity" do
    blank = identity("")

    assert_nil blank.account_last4
    assert_equal [], blank.card_last4s
    assert_not blank.complete?
  end
end
