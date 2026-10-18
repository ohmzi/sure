require "test_helper"

# The behaviour issue #1379 actually asked for: a statement should only offer
# transactions that are not already recorded, and should mark the rest reconciled.
class PdfImportReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family = @account.family
    @statement = create_statement
    @import = PdfImport.create_from_statement!(statement: @statement)
    @import.update!(document_type: "bank_statement")
    @date = Date.current
  end

  # Extractor convention: negative for debits, positive for credits. Import
  # signage ("inflows_positive") flips that into Entry convention, where an
  # expense is positive.
  def extracted(date:, amount:, name:)
    { "date" => date.to_s, "amount" => amount.to_s, "name" => name }
  end

  test "rows are only generated for transactions that are not already recorded" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "COFFEE SHOP"),
      extracted(date: @date, amount: -12, name: "BOOKSTORE")
    ] })

    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
    assert_equal "BOOKSTORE", @import.rows.sole.name
  end

  test "the already-recorded transaction is marked reconciled against the statement" do
    existing = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "COFFEE SHOP") ] })
    @import.generate_rows_from_extracted_data

    existing.reload
    assert_equal :reconciled, existing.reconciliation_state
    assert_equal @statement, existing.reconciled_by_statement
    assert_equal [ existing ], @import.reconciled_entries.to_a
  end

  test "a provider-synced transaction counts as already recorded" do
    synced = create_transaction(
      account: @account, date: @date, amount: 50, name: "COFFEE", external_id: "plaid-1", source: "plaid"
    )

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee Shop") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 0, @import.reload.rows_count
    assert_equal :reconciled, synced.reload.reconciliation_state
  end

  test "a statement date a day or two off the recorded date still matches" do
    create_transaction(account: @account, date: @date - 2, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 0, @import.reload.rows_count
  end

  test "two identical statement lines do not both match one recorded transaction" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -50, name: "Coffee")
    ] })
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count, "the second identical line is genuinely new"
  end

  test "with no account assigned every transaction is offered" do
    @import.update!(account: nil)
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
  end

  test "a row whose date cannot be parsed is offered rather than dropped" do
    @import.update!(extracted_data: { "transactions" => [
      { "date" => "not-a-date", "amount" => "-50", "name" => "Mystery" }
    ] })

    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
  end

  test "a row whose amount cannot be parsed is offered with its raw value intact" do
    @import.update!(extracted_data: { "transactions" => [
      { "date" => @date.to_s, "amount" => "not-a-number", "name" => "Mystery" }
    ] })

    @import.generate_rows_from_extracted_data

    row = @import.reload.rows.sole
    assert_equal 1, @import.rows_count
    # Stored verbatim rather than coerced to 0, so the review step shows the user
    # what the statement actually said.
    assert_equal "not-a-number", row.amount
  end

  test "reassigning the account re-judges the rows and releases the old reconciliation" do
    other = @family.accounts.create!(
      name: "Second Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    on_first = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 0, @import.reload.rows_count

    @import.assign_account!(other)

    assert_not on_first.reload.reconciled?, "the old account's entry is no longer evidence-backed"
    assert_equal 1, @import.reload.rows_count, "nothing on the new account matches, so it is offered"
  end

  test "extract_transactions stores string keys so rows can actually be generated" do
    provider = mock("llm_provider")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.stubs(:extract_bank_statement).returns(
      OpenStruct.new(success?: true, data: { transactions: [ { date: @date.to_s, amount: "-5.0", name: "Coffee" } ] })
    )
    @import.stubs(:pdf_file_content).returns("fake-pdf")

    @import.extract_transactions

    # Without deep_stringify_keys this reads back empty and no rows are built.
    assert_equal 1, @import.extracted_transactions.size
    assert_equal "Coffee", @import.extracted_transactions.first["name"]
  end

  test "publishing does not re-match a row against an entry row generation already consumed" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    # Two identical statement lines, one existing transaction: the first line
    # reconciles against it, the second is genuinely new and must be created.
    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -50, name: "Coffee")
    ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count

    assert_difference -> { @account.entries.count }, 1 do
      @import.import!
    end
  end

  test "assigning an account that reconciles every row completes the import" do
    @import.update!(account: nil, status: :pending)
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count, "nothing matches while no account is assigned"

    @import.assign_account!(@account)

    @import.reload
    assert_equal 0, @import.rows_count
    assert @import.complete?, "a fully reconciled import must finish rather than sit at pending with no rows"
  end

  test "assigning an account that matches nothing returns the import to pending" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.update!(status: :complete)

    other = @family.accounts.create!(
      name: "Untouched Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    # complete but nothing of its own committed: still the user's to re-target.
    assert @import.assign_account!(other)

    @import.reload
    assert_equal 1, @import.rows_count
    assert @import.pending?
  end

  test "a row that cannot be evaluated is recorded in the debug log" do
    @import.update!(extracted_data: { "transactions" => [
      { "date" => "not-a-date", "amount" => "-50", "name" => "Mystery" }
    ] })

    assert_difference "DebugLogEntry.count", 1 do
      @import.generate_rows_from_extracted_data
    end

    logged = DebugLogEntry.last
    assert_equal "import", logged.category
    assert_equal @family, logged.family
    assert_equal @import.id, logged.metadata["import_id"]
  end

  test "regenerating rows twice does not collide on source row numbers" do
    # insert_all! leaves the rows association stale, so a second generation on
    # the same in-memory record used to re-insert source_row_number 1.
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12, name: "Bookstore") ] })

    @import.generate_rows_from_extracted_data
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
    assert_equal 1, @import.rows.count
  end

  test "releasing reconciliations leaves another account's evidence intact" do
    other = @family.accounts.create!(
      name: "Sibling Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    # Same statement, evidence recorded against a second account by another import.
    on_other = create_transaction(account: other, date: @date, amount: 99, name: "Elsewhere")
    on_other.mark_reconciled!(statement: @statement)

    on_first = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert on_first.reload.reconciled?

    @import.assign_account!(other)

    # Both fields matter: reconciled_at is the state, reconciled_by_statement_id
    # is the evidence, and Entry#unmark_reconciled! clears the pair.
    on_first.reload
    assert_not on_first.reconciled?, "the account being left is released"
    assert_nil on_first.reconciled_by_statement_id, "its statement evidence is cleared too"

    on_other.reload
    assert on_other.reconciled?, "another account's evidence must survive"
    assert_equal @statement.id, on_other.reconciled_by_statement_id
  end

  test "reverting a fully reconciled import completes it rather than stranding it at pending" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.update!(status: :complete)
    assert_equal 0, @import.reload.rows_count

    @import.revert

    @import.reload
    assert_nil @import.error
    # pending with no rows renders the processing screen with no way back out.
    assert @import.complete?, "expected complete, got #{@import.status}"
    assert_equal 0, @import.rows_count
  end

  test "reverting an import puts the transactions it created back on offer" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count

    assert_difference -> { @account.entries.count }, 1 do
      @import.import!
    end
    @import.update!(status: :complete)

    assert_difference -> { @account.entries.count }, -1 do
      @import.revert
    end

    @import.reload
    assert @import.pending?, "expected pending, got #{@import.status}"
    assert_equal 1, @import.rows_count, "the created entry is gone, so its statement line is new again"
  end

  test "reverting releases evidence from an entry the statement no longer matches" do
    drifted = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert drifted.reload.reconciled?
    @import.update!(status: :complete)

    # Corrected after the fact, so the statement line no longer describes it.
    drifted.update!(amount: 75)

    @import.revert

    drifted.reload
    assert_not drifted.reconciled?, "a statement that no longer matches must stop claiming the entry"
    assert_nil drifted.reconciled_by_statement_id
    assert_equal 1, @import.reload.rows_count
    assert @import.pending?, "expected pending, got #{@import.status}"
  end

  test "reassigning a published import is refused rather than half-unwinding it" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.import!
    @import.update!(status: :complete)

    other = @family.accounts.create!(
      name: "Wrong Turn Checking", balance: 0, currency: "USD", accountable: Depository.new
    )

    assert_not @import.assign_account!(other), "a replayed PATCH must not unwind a published import"

    @import.reload
    assert_equal @account, @import.account
    assert_equal 1, @import.rows_count, "the rows recording what was published survive"
    assert_equal 1, @import.entries.count
  end

  test "reassigning is refused while a job still owns the record" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.update!(status: :importing)

    other = @family.accounts.create!(
      name: "Mid Flight Checking", balance: 0, currency: "USD", accountable: Depository.new
    )

    assert_not @import.assign_account!(other)
    assert_equal @account, @import.reload.account
  end

  test "the outcome counts separate what was already recorded from what is new" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -12, name: "Bookstore")
    ] })
    @import.generate_rows_from_extracted_data
    @import.reload

    assert_equal 2, @import.extracted_count
    assert_equal 1, @import.already_recorded_count
    assert_equal 0, @import.imported_count
    assert_equal 1, @import.awaiting_review_count
    assert @import.reconciled_anything?
  end

  test "publishing moves the offered rows into the imported count" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -12, name: "Bookstore")
    ] })
    @import.generate_rows_from_extracted_data
    @import.import!
    @import.reload

    # Entries this import created are born reconciled too, so they must not be
    # counted as transactions the account already had.
    assert_equal 1, @import.already_recorded_count
    assert_equal 1, @import.imported_count
    # Rows survive publishing as the record of what was written, so the count
    # has to stop describing them as a queue.
    assert_equal 0, @import.awaiting_review_count
  end

  test "a fully reconciled statement reports everything as already recorded" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.reload

    assert_equal 1, @import.extracted_count
    assert_equal 1, @import.already_recorded_count
    assert_equal 0, @import.imported_count
    assert_equal 0, @import.awaiting_review_count
  end

  test "an import that matched nothing reports nothing as already recorded" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12, name: "Bookstore") ] })
    @import.generate_rows_from_extracted_data
    @import.reload

    assert_equal 0, @import.already_recorded_count
    assert_not @import.reconciled_anything?
  end

  test "a statement never claims an entry it created itself" do
    @statement.archive_document_link!
    @statement.reload

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12.34, name: "Cafe") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count

    @import.import!
    born = @import.entries.sole
    assert_equal @statement.id, born.reconciled_by_statement_id, "born reconciled: the statement is its own evidence"

    # A regeneration re-judges every line against what the account holds now --
    # including this import's own born entries, which find_duplicate_transaction
    # does not exclude. Without the self-attach guard, claim! would hang the
    # statement's own link on its own entry and the document would corroborate
    # itself.
    @import.generate_rows_from_extracted_data
    @import.import!

    born.reload
    assert_not_includes born.document_links.map(&:id), @statement.archived_document_link.id,
                        "a statement must not claim the entry it created itself"
    assert_not EntryProvenance.for(born).corroborated?,
               "a document's own entry must not read as corroborated by that same document"
  end

  test "a sibling import of the same statement never claims the statement's own born entries" do
    @statement.archive_document_link!
    @statement.reload

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12.34, name: "Cafe") ] })
    @import.generate_rows_from_extracted_data
    @import.import!
    born = @import.entries.sole

    # A date-format change makes the first import non-reusable, so a second one
    # is minted for the SAME vault row on the same account. Its row generation
    # re-judges the statement's lines against the account, and this statement's
    # own born entry is among the candidates -- the same self-attach hazard.
    @family.update!(date_format: "%d.%m.%Y")
    sibling = PdfImport.create_from_statement!(statement: @statement)
    assert_not_equal @import, sibling, "the changed format must mint a second import"
    sibling.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12.34, name: "Cafe") ] })
    sibling.generate_rows_from_extracted_data
    assert_equal 0, sibling.reload.rows_count, "the born entry matches, so nothing is offered"

    born.reload
    assert_not_includes born.document_links.map(&:id), @statement.archived_document_link.id,
                        "a sibling import must not claim this statement's own born entry"
    assert_not EntryProvenance.for(born).corroborated?,
               "a sibling import's claim must not make the statement corroborate itself"
  end

  test "re-targeting the statement's account detaches the corroboration it recorded" do
    @statement.archive_document_link!
    @statement.reload
    statement_link = @statement.archived_document_link

    matched = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_includes matched.reload.document_links.map(&:id), statement_link.id,
                    "the statement claims the entry it matched"

    other = @family.accounts.create!(
      name: "Re-targeted Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    @import.assign_account!(other)

    matched.reload
    assert_nil matched.reconciled_by_statement_id,
               "the statement no longer backs an entry on the account it left"
    assert_not_includes matched.document_links.map(&:id), statement_link.id,
                        "a released entry must not keep listing the statement as a corroborating document"
    assert_not EntryProvenance.for(matched).corroborated?,
               "the two provenance signals must agree that the statement is gone"
  end

  test "a row already reconciled to another statement keeps that statement" do
    other = AccountStatement.create_from_upload!(
      family: @family, account: @account,
      file: uploaded_file(
        filename: "other_2026-01-01_2026-01-31.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 other"
      )
    )
    existing = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    existing.mark_reconciled!(statement: other)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "COFFEE") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 0, @import.reload.rows_count, "the row is already recorded"
    assert_equal other, existing.reload.reconciled_by_statement,
                 "a second statement must not steal the first statement's evidence"
  end

  test "a statement whose extracted signs disagree with its printed movement fails to publish" do
    # Depository: closing is 30 above opening, so the saved rows must total -30.
    # A read that flips the sign offers +30 instead.
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -30, name: "Deposit") ] })
    @import.generate_rows_from_extracted_data

    error = assert_raises(PdfImport::ArithmeticMismatchError) { @import.import! }
    assert_match(/do not match the statement/, error.message)
    assert_empty @account.entries.where(name: "Deposit")
  end

  test "a statement whose extracted signs match its printed movement publishes" do
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: 30, name: "Withdrawal") ] })
    @import.generate_rows_from_extracted_data

    assert_difference -> { @account.transactions.count }, 1 do
      @import.import!
    end
  end

  test "a liability statement whose extracted signs match its printed movement publishes" do
    card = accounts(:credit_card)
    statement = AccountStatement.create_from_upload!(
      family: @family, account: card,
      file: uploaded_file(filename: "card.pdf", content_type: "application/pdf", content: "%PDF-1.4 card")
    )
    statement.update!(opening_balance: 100, closing_balance: 130)
    import = PdfImport.create_from_statement!(statement: statement)
    # Extractor convention is inflows-positive; the publisher flips it into
    # Sure's outflows-positive convention. A purchase is -30 on the page and
    # +30 in the ledger, the movement a liability is expected to show.
    import.update!(document_type: "bank_statement",
                   extracted_data: { "transactions" => [ extracted(date: @date, amount: -30, name: "Purchase") ] })
    import.generate_rows_from_extracted_data

    assert_difference -> { card.transactions.count }, 1 do
      import.import!
    end
    assert_equal 30.to_d, card.entries.find_by!(name: "Purchase").amount,
                 "a correct liability sign is written once, never normalized twice"
  end

  test "a liability statement whose extracted signs reverse its printed movement fails to publish" do
    card = accounts(:credit_card)
    statement = AccountStatement.create_from_upload!(
      family: @family, account: card,
      file: uploaded_file(filename: "card.pdf", content_type: "application/pdf", content: "%PDF-1.4 card")
    )
    statement.update!(opening_balance: 100, closing_balance: 130)
    import = PdfImport.create_from_statement!(statement: statement)
    import.update!(document_type: "bank_statement",
                   extracted_data: { "transactions" => [ extracted(date: @date, amount: 30, name: "Purchase") ] })
    import.generate_rows_from_extracted_data

    error = assert_raises(PdfImport::ArithmeticMismatchError) { import.import! }
    assert_match(/reversed signs/, error.message)
    assert_empty card.entries.where(name: "Purchase")
  end

  # The review screen edits Import::Row, never extracted_data. The guard must
  # judge the rows the publish will actually write, or a corrected amount still
  # raises against the stale read.
  test "a corrected row amount publishes even though the extraction disagreed" do
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -30, name: "Deposit") ] })
    @import.generate_rows_from_extracted_data

    @import.rows.sole.update_and_sync(amount: "30")

    assert_difference -> { @account.transactions.count }, 1 do
      @import.import!
    end
  end

  # Lines matched to entries the account already held never become rows, but
  # they are still part of the statement's printed movement. Dropping them from
  # the arithmetic would falsely fail every provider-synced statement.
  test "lines already recorded still count toward the printed movement" do
    create_transaction(account: @account, date: @date, amount: -10, name: "Interest")
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: 10, name: "Interest"),
      extracted(date: @date, amount: 20, name: "Withdrawal")
    ] })
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
    assert_difference -> { @account.transactions.count }, 1 do
      @import.import!
    end
  end

  # The mirror: an edit that breaks the printed movement must be refused even
  # though the original read added up.
  test "an edit that breaks the printed movement blocks publication" do
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: 30, name: "Withdrawal") ] })
    @import.generate_rows_from_extracted_data
    @import.rows.sole.update_and_sync(amount: "50")

    error = assert_raises(PdfImport::ArithmeticMismatchError) { @import.import! }
    assert_match(/do not match the statement/, error.message)
    assert_empty @account.entries.where(name: "Withdrawal")
  end

  # A redelivered publish must answer "already committed" before judging any
  # rows: the rows may have been cleaned up or moved since the commit, and
  # re-checking them would flip a completed import to failed.
  test "a replay after a committed publish returns before the arithmetic guard" do
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: 30, name: "Withdrawal") ] })
    @import.generate_rows_from_extracted_data
    @import.import!
    # Break both sources after the commit: whichever one the guard reads, a
    # replay that re-judged them would flip the completed import to failed.
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Withdrawal") ] })
    @import.rows.sole.update_and_sync(amount: "50")

    assert_no_difference -> { Entry.count } do
      assert_nothing_raised { @import.import! }
    end
  end

  test "publish records the arithmetic mismatch instead of importing it" do
    @statement.update!(opening_balance: 100, closing_balance: 130)

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -30, name: "Deposit") ] })
    @import.generate_rows_from_extracted_data
    @import.publish

    assert @import.reload.failed?
    assert_match(/do not match the statement/, @import.error)
    assert_empty @account.entries.where(name: "Deposit")
  end

  private

    def create_statement
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(
          filename: "statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
