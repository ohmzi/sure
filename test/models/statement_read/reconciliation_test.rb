# frozen_string_literal: true

require "test_helper"

# The gate, over the synthetic statement's own anchors. Each `checks` value is a
# witness: "+" passed, "drift" failed, "skip" no figure to check against.
class StatementRead::ReconciliationTest < ActiveSupport::TestCase
  def text = @text ||= file_fixture("statements/synthetic_statement.txt").read
  def parser = @parser ||= StatementRead::TableParser.call(text)
  def totals = @totals ||= StatementRead::StatedTotals.call(text)

  def reconcile(entries = parser.entries, stated = totals, missing: [], rejected: [])
    StatementRead::Reconciliation.call(entries, stated, text: text,
                                       missing_date_rows: missing, rejected_lines: rejected)
  end

  test "C1-C7 all hold on the statement's own anchors and the read is trusted" do
    result = reconcile

    assert_equal :trusted, result.verdict
    assert result.trusted?
    assert_equal "+", result.checks["row_parse"]
    assert_equal "+", result.checks["credits_sum"]
    assert_equal "+", result.checks["purchases_sum"]
    assert_equal "+", result.checks["charges_identity"]
    assert_equal "+", result.checks["balance_identity"]
    assert_equal "+", result.checks["card_1111"]
    assert_equal "+", result.checks["card_2222"]
    assert_equal "+", result.checks["row_sanity"]
    assert_equal BigDecimal(0), result.rounding_delta
  end

  test "C7's count sub-check resolves to skip when the statement prints no count" do
    assert_equal "skip", reconcile.checks["row_count"]
  end

  test "C5 holds as opening + charges - credits == new balance" do
    assert_equal BigDecimal("1196.78"),
                 totals["opening"] + totals["total_charges"].abs - totals["total_credits"].abs
  end

  test "a mutated amount drifts the purchases sum and the read is not trusted" do
    entries = parser.entries.map(&:dup)
    target = entries.find { |entry| entry["name"].start_with?("TEST MART") }
    target["amount"] = "-500.00"

    result = reconcile(entries)

    assert_equal :drift, result.verdict
    assert_equal "drift", result.checks["purchases_sum"]
    assert_equal BigDecimal("750.00"), result.figures["purchases_sum"][:read]
    assert_equal BigDecimal("350.00"), result.figures["purchases_sum"][:stated]
  end

  test "one cent of drift is still drift — money is exact to the cent" do
    entries = parser.entries.map(&:dup)
    entries.find { |entry| entry["name"].start_with?("TEST MART") }["amount"] = "-100.01"

    assert_equal :drift, reconcile(entries).verdict
  end

  test "zero rows while the statement states a balance is empty_but_expected" do
    result = reconcile([])

    assert_equal :empty_but_expected, result.verdict
    assert_not result.trusted?
  end

  test "no usable totals is unreconcilable, distinct from drift (R-W8B15)" do
    blank_totals = totals.transform_values { |value| value.is_a?(Hash) ? {} : nil }
    result = reconcile(parser.entries, blank_totals)

    assert_equal :unreconcilable, result.verdict
    assert_not result.trusted?
    assert_not_equal :drift, result.verdict
  end

  test "a missing-date row fails C1" do
    result = reconcile(parser.entries, totals, missing: [ "ORPHAN ROW  50.00" ])

    assert_equal "drift", result.checks["row_parse"]
    assert_equal :drift, result.verdict
  end

  test "a line rejected after the drill-down stop fails C1 (R-W8B16)" do
    result = reconcile(parser.entries, totals, rejected: [ "Sep 12  Sep 14  MERCHANT TWO  20.00" ])

    assert_equal "drift", result.checks["row_parse"]
    assert_not result.trusted?
  end
end
