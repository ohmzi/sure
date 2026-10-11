require "test_helper"

class ReceiptImport::ExtractorTest < ActiveSupport::TestCase
  OCR_DIR = Rails.root.join("test/fixtures/files/receipts")

  def extract(name)
    ReceiptImport::Extractor.call(File.read(OCR_DIR.join(name)))
  end

  test "parses the labelled total, the date, the payee and the item lines" do
    extraction = extract("wizard_latte.txt")

    assert_equal BigDecimal("12.00"), extraction.total
    assert_equal Date.new(2026, 9, 14), extraction.date
    assert_equal "LATTE LANE CAFE", extraction.payee
    assert extraction.complete?
    assert_equal %w[Latte Sandwich], extraction.line_items.map(&:description)
    assert_equal BigDecimal("4.75"), extraction.line_items.first.amount
  end

  test "a receipt with no labelled total parses no total and is incomplete" do
    extraction = extract("wizard_no_total.txt")

    assert_nil extraction.total
    assert_not extraction.complete?
    # The item lines are still read — the review screen shows them while the
    # user enters the total by hand; nothing is guessed.
    assert_equal %w[Latte Sandwich], extraction.line_items.map(&:description)
  end

  test "a document with no money produces empty everything" do
    extraction = extract("wizard_items_only.txt")

    assert_nil extraction.total
    assert_nil extraction.date
    assert_empty extraction.line_items
    assert_not extraction.complete?
  end

  test "total labels are never mistaken for items" do
    extraction = extract("wizard_latte.txt")

    assert_not_includes extraction.line_items.map { |i| i.description.upcase }, "TOTAL"
  end
end
