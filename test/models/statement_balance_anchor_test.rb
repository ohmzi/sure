require "test_helper"

# The owner's first description of the feature: a statement "adds account
# updates to the account and then the transactions". A posted statement's
# printed opening balance is what the account held before its rows, so the
# earliest statement anchors the account's opening balance — and the balance
# then ends at the statement's own closing.
class StatementBalanceAnchorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Chequing", balance: 0, currency: "CAD",
                                        accountable: Depository.new)
  end

  def statement(period_start:, opening:, name: "s.pdf")
    s = AccountStatement.create_from_upload!(
      family: @family, account: @account,
      file: Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4 #{name} #{SecureRandom.hex(4)}"), "application/pdf", original_filename: name)
    )
    s.update!(period_start_on: period_start, period_end_on: period_start + 30, opening_balance: opening)
    s
  end

  def entry_on(date, amount, statement: nil)
    import = statement && PdfImport.find_or_create_from_statement!(statement: statement)
    @account.entries.create!(date: date, amount: amount, name: "row", currency: "CAD", entryable: Transaction.new, import: import)
  end

  test "the earliest statement's opening becomes the account's opening balance, before its first row" do
    first = statement(period_start: Date.new(2026, 5, 12), opening: BigDecimal("81.27"))
    entry_on(Date.new(2026, 5, 11), 10, statement: first) # a row dated before the period that the statement still carries

    assert StatementBalanceAnchor.call(first)

    assert_equal BigDecimal("81.27"), @account.reload.opening_anchor_balance
    assert_equal Date.new(2026, 5, 10), @account.opening_anchor_date
  end

  test "a later statement never moves the anchor an earlier one set" do
    earlier = statement(period_start: Date.new(2026, 5, 12), opening: BigDecimal("81.27"), name: "may.pdf")
    later = statement(period_start: Date.new(2026, 6, 12), opening: BigDecimal("1550.58"), name: "june.pdf")
    StatementBalanceAnchor.call(earlier)

    assert_not StatementBalanceAnchor.call(later)
    assert_equal BigDecimal("81.27"), @account.reload.opening_anchor_balance
  end

  test "entries from elsewhere before the statement leave the anchor alone" do
    entry_on(Date.new(2026, 1, 5), 25)
    first = statement(period_start: Date.new(2026, 5, 12), opening: BigDecimal("81.27"))
    @account.update_columns(updated_at: Time.current)

    assert_not StatementBalanceAnchor.call(first)
  end

  test "a statement that prints no opening balance changes nothing" do
    assert_not StatementBalanceAnchor.call(statement(period_start: Date.new(2026, 5, 12), opening: nil))
  end

  test "an account a provider syncs is never re-anchored from a statement" do
    first = statement(period_start: Date.new(2026, 5, 12), opening: BigDecimal("81.27"))
    Account.any_instance.stubs(:manual?).returns(false)

    assert_not StatementBalanceAnchor.call(first)
  end
end
