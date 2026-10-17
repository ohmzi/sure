require "test_helper"

# A transfer's proof (the owner, 2026-10-17): the same amount left one account
# and arrived in another within two weeks, and each side is witnessed by the
# statement it came from when there is one. Witnessed by both banks' statements
# is the strongest proof.
class Transfer::EvidenceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @from = accounts(:depository)
    @to = accounts(:credit_card)
  end

  def statement_document_for(entry)
    link = DocumentLink.create!(family: entry.account.family, source: "statement", status: "linked",
                                original_filename: "#{entry.account.name}.pdf")
    import = Import.create!(family: entry.account.family, type: "TransactionImport")
    import.update_columns(document_link_id: link.id) if import.has_attribute?(:document_link_id)
    entry.update_columns(import_id: import.id)
    link
  end

  test "reports both sides, the gap in days, and no witness without statements" do
    transfer = create_transfer(from_account: @from, to_account: @to, amount: 300, date: Date.new(2026, 9, 3)).reload
    transfer.inflow_transaction.entry.update_columns(date: Date.new(2026, 9, 8))

    evidence = Transfer::Evidence.new(transfer.reload)

    assert_equal [ :out, :in ], evidence.sides.map(&:direction)
    assert_equal [ @from, @to ], evidence.sides.map(&:account)
    assert_equal 5, evidence.days_apart
    assert_equal :none, evidence.witness
  end

  test "is witnessed by both statements when each side came from one" do
    transfer = create_transfer(from_account: @from, to_account: @to, amount: 300).reload
    out_doc = statement_document_for(transfer.outflow_transaction.entry)
    in_doc = statement_document_for(transfer.inflow_transaction.entry)
    skip "imports carry no document link in this schema" unless EntryProvenance.for(transfer.outflow_transaction.entry.reload).creating_document

    evidence = Transfer::Evidence.new(transfer.reload)

    assert_equal [ out_doc, in_doc ], evidence.sides.map(&:document)
    assert_equal :both, evidence.witness
  end

  # The owner's live data: a chequing row is not created by its statement's
  # import but verified against the statement's rows afterwards
  # (reconciled_by_statement). That statement witnesses the side just the same.
  test "a side verified against a statement is witnessed by that statement's document" do
    transfer = create_transfer(from_account: @from, to_account: @to, amount: 300).reload
    statement = AccountStatement.create_from_upload!(
      family: @from.family, account: @from,
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )
    document = statement.archive_document_link!
    transfer.outflow_transaction.entry.update_columns(reconciled_by_statement_id: statement.id, reconciled_at: Time.current)

    evidence = Transfer::Evidence.new(transfer.reload)

    assert_equal document, evidence.sides.first.document
    assert_equal :one, evidence.witness
  end

  test "the automatic match reaches across two weeks" do
    assert_equal 14, Family::AutoTransferMatchable::AUTO_MATCH_DAYS
  end
end
