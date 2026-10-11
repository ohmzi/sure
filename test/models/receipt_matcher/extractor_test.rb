require "test_helper"

class ReceiptMatcher::ExtractorTest < ActiveSupport::TestCase
  OCR_DIR = Rails.root.join("test/fixtures/files/receipts")

  def extract(name)
    ReceiptMatcher::Extractor.call(File.read(OCR_DIR.join(name)))
  end

  test "parses the labelled total, the ISO date and the merchant from a plain receipt" do
    extraction = extract("starbucks.txt")

    assert_equal BigDecimal("55.00"), extraction.amount
    assert_equal Date.new(2026, 9, 14), extraction.date
    assert_equal "Starbucks", extraction.payee
    assert extraction.complete?
  end

  test "falls back to the largest money token when there is no total label" do
    extraction = extract("no_total_label.txt")

    assert_equal BigDecimal("42.10"), extraction.amount
  end

  # (Ruling M3-C2 R4, 2026-10-11 close-out) the labelled total must win even
  # when an unlabelled token is larger, so the TOTAL_LABEL branch is
  # discriminated from the largest-token fallback.
  test "prefers the labelled total over a larger unlabelled money token" do
    extraction = extract("discounted_total.txt")

    assert_equal BigDecimal("1234.56"), extraction.amount, "1,254.56 (catering) is larger but unlabelled"
  end

  test "parses a comma-grouped amount, with date and payee" do
    extraction = extract("discounted_total.txt")

    assert_equal BigDecimal("1234.56"), extraction.amount
    assert_equal Date.new(2026, 9, 15), extraction.date
    assert_equal "Corner Bakery", extraction.payee
  end

  test "reads an ISO date" do
    extraction = extract("iso_date.txt")

    assert_equal Date.new(2026, 1, 3), extraction.date
  end

  test "reads a US slash date as month/day/year when the first field is <= 12" do
    extraction = extract("slash_date_mdy.txt")

    assert_equal Date.new(2026, 9, 14), extraction.date
  end

  test "reads a slash date as day/month/year when the first field is > 12" do
    extraction = extract("slash_date_dmy.txt")

    assert_equal Date.new(2026, 12, 25), extraction.date
  end

  test "returns nil when no amount can be parsed, never a guess" do
    assert_nil extract("unparseable.txt")
  end
end
