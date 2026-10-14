# frozen_string_literal: true

require "test_helper"

# The parser is validated against a SYNTHETIC statement that mirrors the real
# Triangle layout (section headings, dated rows with a transaction + posting
# date, the interleaved right-hand prose, the summary lines, the drill-down
# heading, the stated totals) with invented merchants and amounts:
# `test/fixtures/files/statements/synthetic_statement.txt`.
#
# The numbers asserted here are the brief's verbatim synthetic target:
# 9 rows = 4 charge + 5 credit; purchases 350.00; interest 1.78; charges 351.78;
# credits 5,155.00; per card 300.00 / 50.00.
class StatementRead::TableParserTest < ActiveSupport::TestCase
  def text = @text ||= file_fixture("statements/synthetic_statement.txt").read
  def parser = @parser ||= StatementRead::TableParser.call(text)

  def entries_for(section) = parser.entries.select { |entry| entry["section"] == section }
  def sum_of(section) = entries_for(section).sum(BigDecimal(0)) { |entry| entry["amount"].to_d.abs }

  test "it parses every dated transaction row into the exact row shape" do
    assert_equal 9, parser.row_count, "3 payments + 2 returns + 3 purchases + 1 interest"
    assert parser.rows.all? { |row| row.keys.sort == %w[amount date name notes source_page] },
           "rows are emitted in exactly the shape route_statement consumes"
  end

  test "the bucket sums equal the statement's own printed totals" do
    assert_equal BigDecimal("5155.00"), sum_of(:payments) + sum_of(:returns), "Total credits"
    assert_equal BigDecimal("350.00"), sum_of(:purchases), "Total purchases"
    assert_equal BigDecimal("1.78"), sum_of(:interest)
    assert_equal BigDecimal("351.78"), sum_of(:purchases) + sum_of(:cash) + sum_of(:fees) + sum_of(:interest),
                 "Total charges"
    assert_equal 4, entries_for(:purchases).size + entries_for(:interest).size, "4 charge rows"
    assert_equal 5, entries_for(:payments).size + entries_for(:returns).size, "5 credit rows"
  end

  test "sign comes from the section, never the printed sign" do
    purchase = parser.entries.find { |entry| entry["name"].start_with?("TEST MART") }
    payment = parser.entries.find { |entry| entry["name"].start_with?("RB TELEPAYMENTS") }
    interest = entries_for(:interest).first

    assert_equal "-100.00", purchase["amount"], "a purchase stores negative (row convention)"
    assert_equal "100.00", payment["amount"], "a payment stores positive though printed -100.00"
    assert_equal "-1.78", interest["amount"]
  end

  test "per-card subtotals are carried on the rows" do
    card_1111 = entries_for(:purchases).select { |entry| entry["card"] == "1111" }
    card_2222 = entries_for(:purchases).select { |entry| entry["card"] == "2222" }

    assert_equal 2, card_1111.size
    assert_equal BigDecimal("300.00"), card_1111.sum(BigDecimal(0)) { |entry| entry["amount"].to_d.abs }
    assert_equal 1, card_2222.size
    assert_equal BigDecimal("50.00"), card_2222.sum(BigDecimal(0)) { |entry| entry["amount"].to_d.abs }
  end

  test "the first whole-field amount is taken, so a row with trailing prose is not dropped" do
    payment = parser.entries.find { |entry| entry["name"] == "RB TELEPAYMENTS/TEST DIRECT" && entry["amount"] == "100.00" }

    assert payment, "the amount is not the last token; the row must survive the interleaved prose"
    assert_equal "2026-09-17", payment["date"]
  end

  test "a posting date glued to the description is stripped from the name" do
    returns = entries_for(:returns)

    assert_equal [ "FakeShop.ca TORONTO ON", "TEST Mktp CA TORONTO ON" ], returns.map { |entry| entry["name"] }
  end

  test "a wrapped description is rejoined and an FX detail becomes the row's note" do
    row = parser.entries.find { |entry| entry["name"].start_with?("TEST MART") }

    assert_equal "TEST MART MISSISSAUGA ON HILLPA", row["name"]
    assert_equal "12.00 USD @ 1.234567890", row["notes"]
  end

  test "row dates are re-anchored to the statement's own period (yearless Sep 08 -> 2026)" do
    assert_equal "2026-09-17", parser.rows.first["date"], "the first table on page 2 is payments"
    purchase = parser.entries.find { |entry| entry["name"].start_with?("TEST MART") }
    assert_equal "2026-09-08", purchase["date"], "the period's year, not an invented one"
    assert_equal "2026-10-08", entries_for(:interest).first["date"]
  end

  test "the summary block, the total lines and the page-6 drill-down are never rows" do
    amounts = parser.entries.map { |entry| entry["amount"].to_d.abs }

    assert_not_includes amounts, BigDecimal("999.99"), "the drill-down decoy must be excluded"
    assert_not_includes amounts, BigDecimal("1196.78"), "the new balance is not a row"
    assert_empty entries_for(:cash), "the summary's Cash transactions figure is not a section"
    assert_empty entries_for(:fees)
  end

  test "a statement with no parseable period stops early rather than making every row undated (R-W8B14)" do
    bare = file_fixture("statements/synthetic_statement.txt").read
                        .sub(/For the period:[^\n]*\n/, "").sub(/Statement date:[^\n]*\n/, "")
    result = StatementRead::TableParser.call(bare)

    assert_not result.period_known?
    assert_empty result.entries
    assert_empty result.missing_date_rows, "rows are not turned into a pile of undated ones"
  end

  test "a date-prefixed line after the drill-down stop but before its block marker is recorded (R-W8B16)" do
    text = [
      "For the period: September 9, 2026 to October 8, 2026",
      "Purchases",
      "   Sep 08            Sep 09        MERCHANT ONE                                                     10.00",
      "Details of your Canadian Tire store purchases",
      "Sep 12            Sep 14        MERCHANT TWO                                                     20.00"
    ].join("\n")

    result = StatementRead::TableParser.call(text)

    assert_equal 1, result.rejected_lines.size, "the row after the stop is surfaced, never silently dropped"
    assert result.rejected_lines.first.include?("MERCHANT TWO")
  end

  test "the drill-down block after its annotation is excluded without being flagged" do
    # The synthetic's own drill-down: annotation immediately follows the heading,
    # so the decoy belongs to the itemized block and is excluded, not rejected.
    assert_empty parser.rejected_lines
  end

  test "a continuation with no previous row is dropped, never buffered (R-W8B8)" do
    text = [
      "For the period: September 9, 2026 to October 8, 2026",
      "Purchases",
      "                                   ORPHAN WRAPPED TEXT",
      "   Sep 08            Sep 09        MERCHANT ONE                                                     10.00"
    ].join("\n")

    result = StatementRead::TableParser.call(text)

    assert_equal 1, result.row_count
    assert_equal "MERCHANT ONE", result.rows.first["name"], "the orphan must not pollute the first row"
    assert_empty result.rejected_lines, "a stray continuation is dropped, not rejected"
  end
end
