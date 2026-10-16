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

  test "a non-hash sub-value reads as empty or nil rather than raising" do
    u = DocumentUnderstanding.new(verdict(
      "document_class" => "statement",
      "line_items" => "none",
      "statement_period" => "October 2026",
      "transactions" => "n/a"
    ))

    assert_equal [], u.line_items
    assert_equal [], u.transactions
    assert_nil u.period_start
    assert_nil u.period_end
  end

  test "non-hash members inside a list are dropped while hashes survive" do
    u = DocumentUnderstanding.new(verdict(
      "line_items" => [ "junk", { "description" => "Coffee", "amount" => "3.00" } ]
    ))

    assert_equal 1, u.line_items.size
    assert_equal "Coffee", u.line_items.first["description"]
  end

  test "a hash statement_period is read into dates" do
    u = DocumentUnderstanding.new(verdict(
      "statement_period" => { "start" => "2026-10-01", "end" => "2026-10-31" }
    ))

    assert_equal Date.new(2026, 10, 1), u.period_start
    assert_equal Date.new(2026, 10, 31), u.period_end
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

  test "a statement's rows filed under line_items are read as the statement's rows" do
    # The live local model (qwen2.5vl:7b) reads a statement's table correctly but
    # files every row under `line_items`, leaving `transactions` empty — its field
    # choice varies run to run. Those rows ARE the statement's rows and must not
    # be dropped; the fallback is flagged so it is visible, never silent.
    u = DocumentUnderstanding.new(verdict(
      "document_class" => "statement",
      "transactions" => [],
      "line_items" => [
        { "description" => "ANTHROPIC SAN FRANCISCOC A", "amount" => "-16.52" },
        { "description" => "DEEPSEERWEA", "amount" => "-15.23" }
      ]
    ))

    assert u.statement_rows_from_line_items?
    assert_equal [ "ANTHROPIC SAN FRANCISCOC A", "DEEPSEERWEA" ], u.transactions.map { |r| r["name"] }
    assert_equal [ "-16.52", "-15.23" ], u.transactions.map { |r| r["amount"] }
    assert u.transactions.all? { |r| r["date"].blank? },
           "a line item carries no date; none may be invented"
  end

  test "a statement's own transactions win over the line_items fallback" do
    u = DocumentUnderstanding.new(verdict(
      "document_class" => "statement",
      "transactions" => [ { "date" => "2026-09-03", "amount" => "-12.34", "name" => "Cafe", "notes" => "" } ],
      "line_items" => [ { "description" => "Ignored", "amount" => "-9.99" } ]
    ))

    assert_not u.statement_rows_from_line_items?
    assert_equal [ "Cafe" ], u.transactions.map { |r| r["name"] }
  end

  test "a receipt's line_items are never read as the statement's rows" do
    u = DocumentUnderstanding.new(verdict(
      "document_class" => "receipt", "transactions" => [],
      "line_items" => [ { "description" => "Coffee", "amount" => "3.00" } ]
    ))

    assert_not u.statement_rows_from_line_items?
    assert_empty u.transactions, "a receipt has no statement rows"
    assert_equal [ "Coffee" ], u.line_items.map { |i| i["description"] }
  end

  test "a line item's own date is kept when the model emitted one, never invented when absent" do
    # The generic no-schema read can return a date on a line item; keep it. When
    # there is none, the row's date is left unknown — never faked.
    u = DocumentUnderstanding.new(verdict(
      "document_class" => "statement", "transactions" => [],
      "line_items" => [
        { "description" => "Cafe", "amount" => "-4.50", "date" => "2026-09-03" },
        { "description" => "Fuel", "amount" => "-50.00" }
      ]
    ))

    assert_equal [ "2026-09-03", nil ], u.transactions.map { |row| row["date"] }
  end

  test "the batched read can flag the line_items fallback even when transactions is present" do
    # The mixed-batch case: some pages used transactions, others line_items. The
    # verdict's transactions is non-empty, so the document-level predicate is
    # false — but the job records the per-batch fallback, and the flag must carry.
    u = DocumentUnderstanding.new(verdict(
      "document_class" => "statement",
      "transactions" => [ { "date" => "2026-09-03", "amount" => "-12.34", "name" => "Cafe", "notes" => "" } ]
    )).with_statement_rows_fallback(true)

    assert u.statement_rows_from_line_items?,
           "a page that fell back is flagged even when another page used transactions"
    assert_equal [ "Cafe" ], u.transactions.map { |r| r["name"] }
  end

  # The owner's RBC reads: the model answered currency "$" and the statement
  # failed validation, holding the whole document. A field that is not a real
  # ISO code is no currency at all.
  test "currency is only ever a known ISO code" do
    assert_equal "CAD", DocumentUnderstanding.new("currency" => "cad").currency
    assert_equal "USD", DocumentUnderstanding.new("currency" => "USD").currency
    assert_nil DocumentUnderstanding.new("currency" => "$").currency
    assert_nil DocumentUnderstanding.new("currency" => "CAD$").currency
    assert_nil DocumentUnderstanding.new("currency" => "dollars").currency
  end

  # Review I8: any shape of model output, never an exception.
  test "a field_confidence of any shape reads as no confidence, never an error" do
    [ "high", 1234, [ 1 ], true, 12.5, nil ].each do |shape|
      understanding = DocumentUnderstanding.new("field_confidence" => shape, "total" => "1.00")

      assert_equal({}, understanding.field_confidence.to_h, shape.inspect)
    end
    assert_nil DocumentUnderstanding.new("field_confidence" => { "total" => "sure" }).field_confidence["total"].then { nil }
  end
end
