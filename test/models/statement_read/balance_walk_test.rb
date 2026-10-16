require "test_helper"

# A chequing statement's text loses which column an amount sat in; the running
# balance it moved does not. Each printed balance closes a group of rows, and
# the group's signs are the one assignment that moves the balance by exactly the
# printed difference.
class StatementRead::BalanceWalkTest < ActiveSupport::TestCase
  def row(amount, balance: nil, column: nil) = { "amount" => BigDecimal(amount), "balance" => balance && BigDecimal(balance), "column" => column }

  def walk(rows, opening: "100.00", closing: nil) =
    StatementRead::BalanceWalk.call(opening: BigDecimal(opening), closing: closing && BigDecimal(closing), rows: rows)

  test "signs a group by the balance it moves" do
    result = walk([ row("30.00"), row("50.00", balance: "120.00") ])

    assert result.verified
    assert_equal [ "-30.0", "50.0" ], result.rows.map { |r| r["signed"].to_s("F") }
  end

  test "a trailing group with no printed balance closes against the closing balance" do
    result = walk([ row("10.00", balance: "110.00"), row("5.00") ], closing: "105.00")

    assert result.verified
    assert_equal BigDecimal("-5"), result.rows.last["signed"]
  end

  # Review I1 / spec: an ambiguous group is unverified — a printed column is
  # layout, not proof, and nothing downstream could catch it being wrong.
  test "two fitting assignments are never settled by a column guess" do
    rows = [ row("10.00", column: :deposit), row("10.00", balance: "100.00", column: :withdrawal) ]
    result = walk(rows)

    assert_not result.verified
    assert_equal 1, result.ambiguous_groups
  end

  test "two fitting assignments with no column to decide are never guessed" do
    result = walk([ row("10.00"), row("10.00", balance: "100.00") ])

    assert_not result.verified
    assert_equal 1, result.ambiguous_groups
  end

  test "a group no assignment fits is unverified" do
    result = walk([ row("10.00", balance: "500.00") ])

    assert_not result.verified
  end
end
