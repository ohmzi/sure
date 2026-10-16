require "test_helper"

# The owner's rule for receipts and bills: read the text first — total, date,
# tax, items — and prove them (items = subtotal, subtotal + tax + tip = total);
# the model only fills what the text cannot give. Nothing is ever guessed.
class ReceiptReadTest < ActiveSupport::TestCase
  def read(name) = ReceiptRead.call(file_fixture("receipts/#{name}.txt").read)

  test "a grocery receipt reads and proves its total" do
    r = read("grocery")

    assert_equal BigDecimal("11.92"), r.total
    assert_equal BigDecimal("11.64"), r.subtotal
    assert_equal({ "HST" => BigDecimal("0.28") }, r.taxes)
    assert_equal Date.new(2026, 9, 14), r.date
    assert_equal [ "MILK 2L", "BREAD WHOLE WHEAT", "BANANAS 1.2KG" ], r.items.map { |item| item["description"] }
    assert r.checked
    assert_equal "receipt", r.document_class
    assert_equal "FRESHMART GROCERY #214", r.merchant
  end

  test "a tip counts toward the total" do
    r = read("restaurant")

    assert_equal BigDecimal("44.42"), r.total
    assert_equal BigDecimal("6.00"), r.tip
    assert_equal Date.new(2026, 9, 20), r.date
    assert r.checked
  end

  test "a receipt with no items or tax proves nothing beyond its total" do
    r = read("fuel")

    assert_equal BigDecimal("62.53"), r.total
    assert_equal Date.new(2026, 9, 28), r.date, "09/28 can only be month/day"
    assert_not r.checked, "with nothing to add up, the total is read, not proven"
  end

  test "a bill reads as a bill, its due amount as the total" do
    r = read("utility_bill")

    assert_equal "bill", r.document_class
    assert_equal BigDecimal("137.71"), r.total
    assert_equal Date.new(2026, 9, 5), r.date, "the statement date, not the due date or the period"
    assert r.checked
  end

  test "items that do not add up to the subtotal are never checked" do
    r = ReceiptRead.call(file_fixture("receipts/grocery.txt").read.sub("BANANAS 1.2KG              2.16", "BANANAS 1.2KG              2.99"))

    assert_not r.checked
  end

  test "an ambiguous numeric date is left for the model, never guessed" do
    r = ReceiptRead.call("CORNER STORE\nDATE 03/04/2026\nTOTAL 5.00\n")

    assert_nil r.date
    assert_includes r.missing, "date"
  end

  test "a text with no total reads as nothing" do
    r = ReceiptRead.call("HELLO WORLD\n")

    assert_nil r.total
    assert_not r.complete?
  end
end
