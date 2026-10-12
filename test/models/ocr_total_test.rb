require "test_helper"

class OcrTotalTest < ActiveSupport::TestCase
  test "finds a labelled total" do
    assert_equal BigDecimal("12.34"), OcrTotal.call("ACME\nSUBTOTAL 10.00\nTOTAL 12.34\n")
  end

  test "prefers the grand total label over a bare total" do
    assert_equal BigDecimal("30.00"), OcrTotal.call("TOTAL 12.34\nGRAND TOTAL 30.00")
  end

  test "is nil when there is no labelled total — never the largest number" do
    assert_nil OcrTotal.call("ACME STORE\n4242 1111 2222\n2026-10-01")
  end

  test "is nil on blank input" do
    assert_nil OcrTotal.call("")
    assert_nil OcrTotal.call(nil)
  end
end
