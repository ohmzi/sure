# frozen_string_literal: true

require "test_helper"

class StatementRead::StatedTotalsTest < ActiveSupport::TestCase
  def text = @text ||= file_fixture("statements/synthetic_statement.txt").read
  def totals = @totals ||= StatementRead::StatedTotals.call(text)

  test "it reads the statement's own printed figures" do
    assert_equal BigDecimal("-5155.00"), totals["total_credits"]
    assert_equal BigDecimal("351.78"), totals["total_charges"]
    assert_equal BigDecimal("350.00"), totals["purchases"]
    assert_equal BigDecimal("1.78"), totals["interest"]
    assert_equal BigDecimal("-5125.00"), totals["payments"]
    assert_equal BigDecimal("-30.00"), totals["returns_credits"]
    assert_equal BigDecimal("6000.00"), totals["opening"]
    assert_equal BigDecimal("1196.78"), totals["new_balance"]
  end

  test "per-card subtotals are keyed by the card's last four digits" do
    assert_equal({ "1111" => BigDecimal("300.00"), "2222" => BigDecimal("50.00") }, totals["cards"])
  end

  test "a bare-`Total purchases` line is not satisfied by a `Total purchases for` subtotal" do
    assert_equal BigDecimal("350.00"), totals["purchases"], "the per-card lines must not leak into the grand total"
  end

  test "every figure is nil when the statement prints none" do
    bare = StatementRead::StatedTotals.call("Sep 09  MERCHANT  12.34\n")

    assert_nil bare["total_credits"]
    assert_nil bare["total_charges"]
    assert_nil bare["purchases"]
    assert_nil bare["new_balance"]
    assert_equal({}, bare["cards"])
  end
end
