require "test_helper"

# RBC personal chequing (the owner's "Chequing Statement-6719" uploads). The
# text layer keeps no Withdrawals/Deposits labels on the amounts, so a row's
# direction comes from the running balance it moves; the fixture is the live
# October statement's layout with the personal details replaced.
class StatementRead::Layouts::RbcChequingTest < ActiveSupport::TestCase
  def text = @text ||= file_fixture("statements/rbc_chequing_synthetic.txt").read
  def read(source = text) = StatementRead::Layouts::RbcChequing.call(source)
  def amounts(result) = result.rows.map { |row| [ row["name"], row["amount"] ] }.to_h

  test "is recognised by the registry, and a Triangle statement is not" do
    assert_equal StatementRead::Layouts::RbcChequing, StatementRead::Layout.detect(text)
    assert_nil StatementRead::Layout.detect(file_fixture("statements/synthetic_statement.txt").read)
  end

  test "reads the account, institution and period from the page" do
    identity = read.identity

    assert_equal "5550001".last(4), identity.account_last4
    assert_equal "Royal Bank of Canada", identity.institution_name
    assert_equal Date.new(2026, 9, 11), identity.period_start
    assert_equal Date.new(2026, 10, 9), identity.period_end
  end

  test "reads every row and proves them against the printed totals and running balances" do
    result = read

    assert_equal 18, result.row_count
    assert result.reconciled?, result.checks.inspect
    assert_equal :trusted, result.verdict
    assert_equal({ "opening" => "2.05", "deposits" => "10566.0", "withdrawals" => "9697.64", "closing" => "870.41" },
                 result.stated_totals.slice("opening", "deposits", "withdrawals", "closing").transform_values { |v| v.to_s("F") })
  end

  test "a deposit is money in and a withdrawal money out, decided by the balance" do
    rows = amounts(read)

    assert_equal "200.00", rows["Online Banking transfer - 0089"]
    assert_equal "-232.00", rows["e-Transfer Request Fulfilled Alex Sample BZ8LDQ"]
    # Named like income, but the balance only works as a withdrawal.
    assert_equal "-15.00", rows["Payroll Deposit Acme"]
  end

  test "a foreign amount inside the description is a note, not the charge" do
    row = read.rows.find { |candidate| candidate["name"].start_with?("Interac purchase") }

    assert_equal "-23.47", row["amount"]
    assert_includes row["notes"].to_s, "16.25"
  end

  test "rows keep their dates across lines and pages, with the period's year" do
    rows = read.rows

    assert_equal "2026-09-15", rows.first["date"]
    assert_equal "2026-09-29", rows.find { |row| row["name"].include?("2HERHE") }["date"], "a continued date carries over the page break"
    assert_equal "2026-10-09", rows.last["date"]
  end

  test "a statement whose totals disagree with its rows is a drift, never trusted" do
    tampered = text.sub("Total deposits into your account", "Total deposits into your account     + 1.00\nX")
                   .sub(/Your closing balance on October 9, 2026\s+= \$870\.41/, "Your closing balance on October 9, 2026   = $871.41")
    result = read(tampered)

    assert_not result.reconciled?
    assert_equal :drift, result.verdict
  end

  test "rows emit exactly the five keys the import expects" do
    assert_equal %w[amount date name notes source_page], read.rows.first.keys.sort
  end

  # Review I7: a page's own header (the bank's address block, the statement
  # title) must never be read into the next transaction's description.
  test "the next page's header is not glued into a transaction name" do
    with_header = text.sub("Details of your account activity - continued",
                           "Royal Bank of Canada   C.P. 6011 Station A   Your RBC personal banking\nMontreal QC H3C 3B8   account statement\nDetails of your account activity - continued")
    names = read(with_header).rows.map { |row| row["name"] }

    assert names.none? { |name| name.include?("Station A") || name.include?("Montreal") }, names.inspect
    assert_equal 18, read(with_header).row_count
  end
end
