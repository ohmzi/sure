require "test_helper"

# A model reads a statement's rows in the statement's OWN printed signs (a
# payment "-500.00"); the import expects the reader's convention (credits
# positive, charges negative). Imported unchanged, every payment would become
# an expense. Probed live 2026-10-16: DeepSeek and Gemini both print the
# statement's signs.
class StatementRead::SignOrientationTest < ActiveSupport::TestCase
  TOTALS = {
    "opening" => BigDecimal("1000.00"), "total_credits" => BigDecimal("-500.00"),
    "total_charges" => BigDecimal("20.00"), "new_balance" => BigDecimal("520.00")
  }.freeze

  PRINTED = [
    { "date" => "2026-05-11", "amount" => "-500.00", "name" => "CTFS.COM/PAYMENTS OAKVILLE ON" },
    { "date" => "2026-05-12", "amount" => "15.75", "name" => "SQ *SABIQOUNBOOKS.COM" },
    { "date" => "2026-05-13", "amount" => "4.25", "name" => "METRO 214" }
  ].freeze

  def orient(rows, totals = TOTALS) = StatementRead::SignOrientation.call(rows, totals)

  test "flips rows printed in the statement's signs when only the flip balances" do
    result = orient(PRINTED)

    assert_equal :flipped, result.orientation
    assert result.verified
    assert_equal %w[500.00 -15.75 -4.25], result.rows.map { |row| row["amount"] }
    assert_equal "CTFS.COM/PAYMENTS OAKVILLE ON", result.rows.first["name"], "only the amount changes"
  end

  test "keeps rows already in the reader's convention" do
    reader_rows = orient(PRINTED).rows
    result = orient(reader_rows)

    assert_equal :as_read, result.orientation
    assert result.verified
    assert_equal reader_rows, result.rows
  end

  test "reads currency-formatted amounts" do
    rows = PRINTED.map { |row| row.merge("amount" => row["amount"].sub(/\A(-?)/, '\1$')) }
    rows[0] = rows[0].merge("amount" => "-$500.00")

    assert_equal "500.00", orient(rows).rows.first["amount"]
  end

  test "without printed totals, a payment printed negative still decides the flip" do
    result = orient(PRINTED, {})

    assert_equal :keywords, result.orientation
    assert_not result.verified
    assert_equal "500.00", result.rows.first["amount"]
  end

  test "without totals or a credit-named row, nothing can decide" do
    rows = PRINTED.drop(1)
    result = orient(rows, {})

    assert_equal :undecided, result.orientation
    assert_not result.verified
    assert_equal rows, result.rows
  end

  # Review finding C1: a card paid in full with matching spend prints equal
  # credits and charges, so BOTH orientations balance and the totals cannot
  # tell them apart. The flip must not be claimed as verified.
  test "when both orientations balance, the totals decide nothing and the read is unverified" do
    rows = [
      { "date" => "2026-05-11", "amount" => "-40.00", "name" => "PAYMENT THANK YOU" },
      { "date" => "2026-05-12", "amount" => "25.00", "name" => "STREAMING" },
      { "date" => "2026-05-13", "amount" => "15.00", "name" => "MUSIC" }
    ]
    symmetric = { "opening" => BigDecimal("100"), "total_credits" => BigDecimal("-40"),
                  "total_charges" => BigDecimal("40"), "new_balance" => BigDecimal("100") }

    result = orient(rows, symmetric)

    assert_not result.verified
    assert_equal :keywords, result.orientation
    assert_equal "40.00", result.rows.first["amount"], "the credit-named row still decides the flip"
  end
end
