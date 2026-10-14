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

  # --- W8-E: numeric dates and ungrouped amounts -------------------------------

  # A synthetic statement in numeric-date + ungrouped-amount style:
  # `test/fixtures/files/statements/synthetic_statement_numeric.txt`. Same shape
  # and self-consistent totals as the month-name fixture (9 rows = 4 charge +
  # 5 credit; purchases 350.00; interest 1.78; charges 351.78; credits 5,155.00;
  # per card 300.00 / 50.00), printed without comma grouping.
  def numeric_text = @numeric_text ||= file_fixture("statements/synthetic_statement_numeric.txt").read
  def numeric_parser = @numeric_parser ||= StatementRead::TableParser.call(numeric_text)

  test "a numeric-date statement parses: yearless from the period, explicit and two-digit years honoured (W8-E)" do
    assert_equal 9, numeric_parser.row_count, "3 payments + 2 returns + 3 purchases + 1 interest"
    assert_equal Date.new(2026, 9, 9), numeric_parser.period_start, "an mm/dd/yyyy period reads month-first, not day-first"
    assert_equal Date.new(2026, 10, 8), numeric_parser.period_end
    assert_equal "2026-09-17", numeric_parser.rows.first["date"], "a yearless 09/17 takes the statement's period year"

    by_name = numeric_parser.entries.index_by { |entry| entry["name"] }
    assert_equal "2026-09-08", by_name["TEST MART MISSISSAUGA ON HILLPA"]["date"],
                 "an explicit four-digit 09/08/2026 year is honoured as printed"
    assert_equal "2026-09-10", by_name["GROCERY STORE TORONTO ON"]["date"],
                 "a two-digit 09/10/26 resolves to the century nearest the period (2026)"
    assert_equal "2026-10-08", by_name["INTEREST CHARGES"]["date"]
  end

  test "a whole-field amount is money grouped or ungrouped, and nothing else is (W8-E)" do
    money = %w[1,234.56 1234.56 1000.00 -1000.00 $1234.56 -$1,234.56 0.00]
    not_money = %w[22.99% 0.06024% 1234 12.5 1,23.45 09/09]
    money.each { |token| assert amount_field?(token), "#{token} must be a whole-field amount" }
    not_money.each { |token| assert_not amount_field?(token), "#{token} must NOT be a whole-field amount" }
  end

  test "an entirely two-digit statement keeps the deterministic path to :trusted (cleanup item 2)" do
    # A statement printed ENTIRELY in two-digit form — its period, its statement
    # date and every row carry a two-digit year. The row anchor already accepted
    # `09/09/26`; before the period pattern did too, `period_known?` was false and
    # the whole read was refused as `:period_unreadable`. Derived from the numeric
    # fixture (self-consistent) with every `2026` printed as `26`.
    two_digit = numeric_text.gsub("2026", "26")
    parser = StatementRead::TableParser.call(two_digit)

    assert parser.period_known?, "a two-digit period is no longer refused as period-unreadable"
    assert_equal Date.new(2026, 9, 9), parser.period_start, "the two-digit period resolves to the nearest century (2026)"
    assert_equal Date.new(2026, 10, 8), parser.period_end
    assert_equal 9, parser.row_count, "the rows the anchor detected are now datable, not dropped"

    recon = StatementRead::Reconciliation.call(
      parser.entries, StatementRead::StatedTotals.call(two_digit),
      text: two_digit, missing_date_rows: parser.missing_date_rows, rejected_lines: parser.rejected_lines
    )
    assert_equal :trusted, recon.verdict, "a fully two-digit statement reconciles to :trusted"
    assert recon.trusted?
  end

  test "a numeric date mid-line is never a row, and a rate is never money (W8-E)" do
    text = [
      "For the period: 09/09/2026 to 10/08/2026",
      "Purchases",
      "   09/08            09/09         MERCHANT ONE                                                     10.00",
      "   Rate notice: as of 09/15/2026 the rate is 21.99% and the fee is 1.5",
      "   Balance Due 09/15/2026                                                   1196.78"
    ].join("\n")
    result = StatementRead::TableParser.call(text)

    assert_equal 1, result.row_count, "only the date-LEAD line is a row; a mid-line date is never one"
    assert_equal "MERCHANT ONE", result.rows.first["name"]
    assert_empty result.missing_date_rows, "21.99% and 1.5 are not whole-field money, so no dateless row is surfaced"
  end

  def amount_field?(token) = StatementRead::TableParser::AMOUNT_FIELD.match?(token)
end
