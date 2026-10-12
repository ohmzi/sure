require "test_helper"

class DocumentUnderstandingTest < ActiveSupport::TestCase
  def verdict(overrides = {})
    {
      "document_class" => "receipt",
      "institution_name" => "Acme",
      "account_last4" => nil,
      "card_last4" => "4242",
      "card_network" => "visa",
      "statement_period" => nil,
      "currency" => "USD",
      "total" => "12.34",
      "date" => "2026-10-03",
      "payee" => "Acme Store",
      "line_items" => [
        { "description" => "Coffee", "amount" => "3.00" },
        { "description" => "Beans", "amount" => "9.34" }
      ],
      "field_confidence" => { "total" => 0.99, "date" => 0.9 }
    }.merge(overrides)
  end

  test "reads the flat verdict by name" do
    u = DocumentUnderstanding.new(verdict)

    assert_equal "receipt", u.document_class
    assert_equal BigDecimal("12.34"), u.total
    assert_equal Date.new(2026, 10, 3), u.date
    assert_equal "Acme Store", u.payee
    assert_equal "4242", u.card_last4
    assert_equal 2, u.line_items.size
  end

  test "an unparseable field is nil, never raised" do
    u = DocumentUnderstanding.new(verdict("date" => "not a date", "total" => "12,34,5"))

    assert_nil u.date
    assert_nil u.total
  end

  test "an out-of-vocabulary class reads as nil so the classifier can refuse it" do
    u = DocumentUnderstanding.new(verdict("document_class" => "invoice"))

    assert_nil u.document_class
  end

  test "to_verdict round-trips for storage" do
    u = DocumentUnderstanding.new(verdict)
    assert_equal "receipt", u.to_verdict["document_class"]
    assert_equal "4242", u.to_verdict["card_last4"]
  end

  test "transactions is empty unless the class is a statement" do
    receipt = DocumentUnderstanding.new(verdict)
    assert_empty receipt.transactions

    statement = DocumentUnderstanding.new(verdict(
      "document_class" => "statement",
      "transactions" => [ { "date" => "2026-10-01", "amount" => "-4.50", "name" => "Cafe", "notes" => "" } ]
    ))
    assert_equal 1, statement.transactions.size
    assert_equal "-4.50", statement.transactions.first["amount"]
  end
end
