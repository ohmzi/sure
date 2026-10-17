require "test_helper"

# How and where a transaction was found in a document (the owner, 2026-10-17):
# opened from a transaction, the viewer talks about that transaction — the
# statement line it came from, the page, and how it got into the account — not
# about the statement as a whole.
class Entry::DocumentTraceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @import = statement_import
    @link = @import.document_link
    @import.update!(extracted_data: { "transactions" => [
      { "date" => "2026-09-29", "amount" => "-1500.00", "name" => "e-Transfer Canadian Tire Bank 2HERHE", "source_page" => nil },
      { "date" => "2026-10-02", "amount" => "-1500.00", "name" => "e-Transfer Canadian Tire Bank USM3UF", "source_page" => 2 },
      { "date" => "2026-10-05", "amount" => "566.00", "name" => "Loan Borrowell", "source_page" => 2 }
    ] })
  end

  test "an entry the statement's import created names its line, row and page" do
    entry = create_transaction(name: "e-Transfer Canadian Tire Bank USM3UF", amount: 1500, date: Date.new(2026, 10, 2), import: @import)

    trace = Entry::DocumentTrace.for(entry, @link)

    assert_equal :created, trace.how
    assert_equal "e-Transfer Canadian Tire Bank USM3UF", trace.line.name
    assert_equal Date.new(2026, 10, 2), trace.line.date
    assert_equal BigDecimal("1500"), trace.line.amount
    assert_equal 2, trace.line.row_number
    assert_equal 2, trace.page
    assert_equal 0, trace.days_apart
    assert trace.amount_matches?
  end

  test "an entry the statement only verified picks its line by amount and the nearest date" do
    entry = create_transaction(name: "CTFS PAYMENT", amount: 1500, date: Date.new(2026, 9, 30))
    entry.mark_reconciled!(statement: @import.account_statement)

    trace = Entry::DocumentTrace.for(entry, @link)

    assert_equal :verified, trace.how
    assert_equal 1, trace.line.row_number
    assert_equal 1, trace.days_apart
  end

  test "a receipt matched to the entry is the matched kind, with no statement line" do
    entry = create_transaction(amount: 12)
    receipt = document_links(:understood_receipt_link)
    receipt.update!(entry_id: entry.id)

    trace = Entry::DocumentTrace.for(entry, receipt)

    assert_equal :matched, trace.how
    assert_nil trace.line
  end

  test "a document the entry has nothing to do with has no trace" do
    assert_nil Entry::DocumentTrace.for(create_transaction(amount: 1500), @link)
  end

  private
    def statement_import
      statement = AccountStatement.create_from_upload!(
        family: families(:dylan_family),
        account: accounts(:depository),
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf",
                            content: file_fixture("imports/sample_bank_statement.pdf").binread)
      )
      statement.archive_document_link!
      PdfImport.create_from_statement!(statement: statement.reload)
    end
end
