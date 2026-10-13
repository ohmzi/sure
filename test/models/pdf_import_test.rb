require "test_helper"

class PdfImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:pdf)
    @processed_import = imports(:pdf_processed)
    @import_with_rows = imports(:pdf_with_rows)
  end

  test "pdf_uploaded? returns false when no file attached" do
    assert_not @import.pdf_uploaded?
  end

  test "pdf_uploaded? returns true for statement backed import" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert import.pdf_uploaded?
    assert import.statement_backed?
    assert_equal statement.original_file.download, import.pdf_file_content
    assert_equal statement.filename, import.pdf_filename
  end

  test "ai_processed? returns false when no summary present" do
    assert_not @import.ai_processed?
  end

  test "ai_processed? returns true when summary present" do
    assert @processed_import.ai_processed?
  end

  test "uploaded? delegates to pdf_uploaded?" do
    assert_not @import.uploaded?
  end

  test "configured? requires AI processed and rows" do
    assert_not @import.configured?
    assert_not @processed_import.configured?
    assert @import_with_rows.configured?
  end

  test "cleaned? requires configured and valid rows" do
    assert_not @import.cleaned?
    assert_not @processed_import.cleaned?
  end

  test "publishable? requires bank statement with cleaned rows and valid mappings" do
    assert_not @import.publishable?
    assert_not @processed_import.publishable?
  end

  test "status detail cleaned check requires account and transaction statement" do
    @import_with_rows.update!(account: accounts(:depository), document_type: "bank_statement")

    assert @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 1)

    @import_with_rows.update!(account: nil)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)

    @import_with_rows.update!(account: accounts(:depository), document_type: "other")
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
  end

  test "column_keys returns transaction columns" do
    assert_equal %i[date amount name category notes], @import.column_keys
  end

  test "required_column_keys returns date and amount" do
    assert_equal %i[date amount], @import.required_column_keys
  end

  test "document_type validates against allowed types" do
    @import.document_type = "bank_statement"
    assert @import.valid?

    @import.document_type = "invalid_type"
    assert_not @import.valid?
    assert @import.errors[:document_type].present?
  end

  test "document_type allows nil" do
    @import.document_type = nil
    assert @import.valid?
  end

  test "process_with_ai_later enqueues ProcessPdfJob" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_with job: ProcessPdfJob, args: [ import ] do
      assert import.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not enqueue duplicate jobs while importing" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_jobs 1, only: ProcessPdfJob do
      assert import.process_with_ai_later
      assert_not import.reload.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not claim import without pdf content" do
    assert_no_enqueued_jobs only: ProcessPdfJob do
      assert_not @import.process_with_ai_later
    end

    assert_equal "pending", @import.reload.status
  end

  test "process_with_ai_later resets pending when enqueue fails" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    ProcessPdfJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_not import.process_with_ai_later
    assert_equal "pending", import.reload.status
  end

  test "generate_rows_from_extracted_data creates import rows" do
    import = imports(:pdf_with_rows)
    import.rows.destroy_all
    import.update_column(:rows_count, 0)

    import.generate_rows_from_extracted_data

    assert_equal 2, import.rows.count
    assert_equal 2, import.rows_count

    coffee_row = import.rows.find_by(name: "Coffee Shop")
    assert_not_nil coffee_row
    assert_equal "-50.0", coffee_row.amount
    assert_equal "Food & Drink", coffee_row.category

    salary_row = import.rows.find_by(name: "Salary")
    assert_not_nil salary_row
    assert_equal "1500.0", salary_row.amount
  end

  test "generate_rows_from_extracted_data does nothing without extracted transactions" do
    @import.generate_rows_from_extracted_data
    assert_equal 0, @import.rows.count
  end

  test "extracted_transactions returns transactions from extracted_data" do
    assert_equal 2, @import_with_rows.extracted_transactions.size
    assert_equal "Coffee Shop", @import_with_rows.extracted_transactions.first["name"]
  end

  test "extracted_transactions returns empty array when no data" do
    assert_equal [], @import.extracted_transactions
  end

  test "has_extracted_transactions? returns true with transactions" do
    assert @import_with_rows.has_extracted_transactions?
  end

  test "has_extracted_transactions? returns false without transactions" do
    assert_not @import.has_extracted_transactions?
  end

  test "mapping_steps is empty when no categories in rows" do
    # PDF imports use direct account selection in UI, not AccountMapping
    assert_equal [], @import.mapping_steps
  end

  test "mapping_steps includes CategoryMapping when rows have categories" do
    @import_with_rows.rows.create!(
      source_row_number: 1,
      date: "01/15/2024",
      amount: -50.00,
      currency: "USD",
      name: "Test Transaction",
      category: "Groceries"
    )
    assert_equal [ Import::CategoryMapping ], @import_with_rows.mapping_steps
  end

  test "mapping_steps does not include AccountMapping even when account is nil" do
    # PDF imports handle account selection via direct UI, not mapping system
    assert_nil @import.account
    assert_not_includes @import.mapping_steps, Import::AccountMapping
  end

  test "destroying import purges attached pdf_file" do
    @import.pdf_file.attach(
      io: StringIO.new("fake-pdf-content"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )

    attachment_id = @import.pdf_file.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      @import.destroy!
    end

    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "destroying statement backed import keeps statement file" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    attachment_id = statement.original_file.id

    perform_enqueued_jobs do
      import.destroy!
    end

    assert ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "statement backed import prevents source statement destroy" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert_no_difference "AccountStatement.count" do
      assert_not statement.destroy
    end

    assert_equal statement, import.reload.account_statement
  end

  test "statement backed import memoizes pdf content" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    statement.original_file.expects(:download).once.returns("%PDF-test")

    assert_equal "%PDF-test", import.pdf_file_content
    assert_equal "%PDF-test", import.pdf_file_content
  end

  test "statement backed import reuse requires current account and date format" do
    statement = create_pdf_statement
    stale_import = PdfImport.create_from_statement!(statement: statement)
    formats = Family::DATE_FORMATS.map(&:last)
    alternate_date_format = (formats - [ statement.family.date_format ]).first || "#{statement.family.date_format}-alternate"
    stale_import.update!(account: nil, date_format: alternate_date_format)

    fresh_import = PdfImport.create_from_statement!(statement: statement)

    assert_not_equal stale_import, fresh_import
    assert_equal statement.account, fresh_import.account
    assert_equal statement.family.date_format, fresh_import.date_format
  end

  test "statement backed import reuses matching reusable import" do
    statement = create_pdf_statement
    existing_import = PdfImport.create_from_statement!(statement: statement)

    assert_equal existing_import, PdfImport.create_from_statement!(statement: statement)
  end

  test "find_or_create_from_statement! adopts the statement's existing import" do
    # The native read's entry point (Task 9): a retry, a reaper re-enqueue or a
    # reprocess must adopt the import the statement already has rather than mint
    # a second one (and a second set of rows) against the same vault row.
    statement = create_pdf_statement

    import = PdfImport.find_or_create_from_statement!(statement: statement)
    assert_equal statement, import.account_statement

    assert_no_difference -> { PdfImport.count } do
      assert_equal import, PdfImport.find_or_create_from_statement!(statement: statement)
    end
  end

  test "a statement row matching an auto-posted receipt claims it instead of duplicating it" do
    account = accounts(:depository)
    link = document_links(:understood_receipt_link)
    link.update!(entry_id: nil)

    statement = create_pdf_statement(account: account)
    statement_link = statement.archive_document_link!
    # archive_document_link! caches a nil read of its own has_one while building
    # the link, so re-read it before the import shares the same statement object.
    statement.reload

    # A receipt already auto-posted this charge (identity `document:<link id>`),
    # the shape Milestone A's Task 8 minted.
    draft = ReceiptImport.find_by!(document_link: link)
    draft.update!(account: account, extracted_data: {
      "total" => "12.34", "date" => "2026-10-03", "payee" => "Cafe", "line_items" => []
    })
    draft.import!
    posted = draft.reload.document_link.entry
    assert_not_nil posted, "the receipt must post its entry before the statement arrives"

    # The statement covers the same money under a different identity entirely.
    import = PdfImport.create_from_statement!(statement: statement)
    import.update!(account: account, extracted_data: { "transactions" => [
      { "date" => "2026-10-04", "amount" => "-12.34", "name" => "CAFE", "notes" => "" }
    ] })
    import.generate_rows_from_extracted_data

    assert_no_difference -> { Entry.count } do
      import.import!
    end

    posted.reload
    assert_equal statement.id, posted.reconciled_by_statement_id,
                 "the statement must claim the entry the receipt posted"
    assert_includes posted.document_links.map(&:id), statement_link.id,
                    "both documents must be visible on the one transaction"
  end

  test "assigning account links statement backed import statement" do
    statement = create_pdf_statement(account: nil)
    import = PdfImport.create_from_statement!(statement: statement)
    account = accounts(:depository)

    import.assign_account!(account)

    assert_equal account, import.reload.account
    assert_equal account, statement.reload.account
    assert statement.linked?
  end

  test "statement backed import requires pdf statement" do
    csv_statement = AccountStatement.create_from_upload!(
      family: @import.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    import = PdfImport.new(family: @import.family, account_statement: csv_statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  test "statement backed import requires statement from same family" do
    statement = AccountStatement.create_from_upload!(
      family: families(:empty),
      account: nil,
      file: uploaded_file(
        filename: "other_family_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    import = PdfImport.new(family: @import.family, account_statement: statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  private

    def create_pdf_statement(account: accounts(:depository))
      AccountStatement.create_from_upload!(
        family: @import.family,
        account: account,
        file: uploaded_file(
          filename: "sample_bank_statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end

# A genuine concurrent double-submit needs a second, concurrently-committing
# connection to reproduce: with the committed check and the write unshared by
# any lock (the pre-M2-C10 shape), the second submit ran the writer while the
# first was mid-publish and double-posted the statement's entries (the
# Ruling-M7-L8 class, closed for M2's money writer by Ruling M2-C10). Runs
# without transactional fixtures so the writer thread's commit is visible to
# the reader's separate connection (the ReceiptImportConcurrentPublishTest /
# FamilyMerchantConcurrencyTest precedent in test/models/family_merchant_test.rb).
class PdfImportConcurrentPublishTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    # The test's main thread, writer thread and reader thread each hold their
    # own checked-out connection at once. The default pool (RAILS_MAX_THREADS,
    # 3) leaves zero headroom for that, so under CI's parallelized test load a
    # thread's connection checkout can itself queue behind another test's use
    # of the pool, throwing off the race entirely. Widen it for this test only.
    @original_db_config = ActiveRecord::Base.connection_db_config
    if @original_db_config.max_connections.to_i < 6
      ActiveRecord::Base.establish_connection(@original_db_config.configuration_hash.except(:pool).merge(max_connections: 6))
    else
      @original_db_config = nil
    end

    # Each publish closes through Import#publish's family.sync_later, which
    # creates a Sync row for the family (no transactional rollback here);
    # remember the pre-existing ones so the teardown removes only this test's.
    @family = imports(:pdf_with_rows).family
    @existing_sync_ids = @family.syncs.pluck(:id)
  end

  teardown do
    # This class commits (no transactional rollback), so remove exactly what
    # the test wrote before the fixture set is reused: the statement's entries
    # (each destroys with its transaction), the generated rows, and any sync
    # row the publishes created.
    import = imports(:pdf_with_rows)
    import.entries.destroy_all
    import.rows.destroy_all
    @family.syncs.where.not(id: @existing_sync_ids).destroy_all
  ensure
    ActiveRecord::Base.establish_connection(@original_db_config) if @original_db_config
  end

  test "a concurrent double-submit serializes on the statement's row lock and the entries post exactly once" do
    import = imports(:pdf_with_rows)
    # The fixture's own account reference is dangling (there is no `checking`
    # accounts fixture), so assign the depository the way this file's other
    # publish-shaped tests do, then build the reviewable rows a statement
    # would carry.
    import.update!(account: accounts(:depository))
    import.generate_rows_from_extracted_data
    assert_equal 2, import.reload.rows_count

    writer_entered = Queue.new
    release_writer = Queue.new
    reader_pid = Queue.new

    # The writer runs the real publish -> import!; its `reconcile_entries!`
    # call sits INSIDE the locked section, after the entry write — pausing
    # there parks the writer mid-transaction holding the statement's row lock
    # with an uncommitted entry batch, exactly the window a second submit
    # races.
    writer_import = PdfImport.find(import.id)
    writer_import.define_singleton_method(:reconcile_entries!) do |entries, at: Time.current|
      writer_entered << true
      release_writer.pop
      super(entries, at: at)
    end

    writer = nil
    reader = nil

    begin
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          writer_import.publish
        end
      end

      writer_entered.pop

      reader = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          reader_pid << connection.select_value("SELECT pg_backend_pid()")

          PdfImport.find(import.id).publish
        end
      end

      pid = reader_pid.pop.to_i

      # Wait until Postgres itself reports the reader blocked on a lock — the
      # writer's SELECT ... FOR UPDATE of the statement row — proving the two
      # submits genuinely overlap. Only then is releasing the writer
      # guaranteed to exercise the serialization rather than a sequential
      # replay.
      deadline = Time.current + 10.seconds
      wait_event_type = nil
      loop do
        wait_event_type = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{pid}"
        )
        break if wait_event_type == "Lock" || Time.current > deadline || !reader.alive?
        sleep 0.01
      end

      release_writer << true
      writer.value # joins the writer and re-raises anything it raised
      reader.value # likewise; the loser of the race must return, not raise

      # Without the row lock the reader never blocks; both submits run the
      # writer unsupervised and the statement posts every entry twice. This is
      # the failure the test exists to catch (RED: the count reads 4 for 2
      # rows here).
      unless wait_event_type == "Lock"
        flunk "reader never blocked on the statement's row lock (wait_event_type=#{wait_event_type.inspect}); " \
              "the two submits ran unsupervised and the statement posted #{import.entries.reload.count} entries " \
              "for #{import.rows_count} rows; the race wasn't serialized"
      end

      import.reload
      assert_equal 2, import.entries.count, "the statement's entries must be posted exactly once"
      assert_equal 1, import.entries.where(name: "Coffee Shop").count, "the second submit must add zero entries"
      assert_equal 1, import.entries.where(name: "Salary").count, "the second submit must add zero entries"
      assert_equal "complete", import.status, "the import must end in its terminal published state"
    ensure
      # Unblocks the writer even if an assertion above failed, so its thread
      # (and checked-out connection) don't leak past this test.
      release_writer << true
      writer&.join(2)
      reader&.join(2)
    end
  end
end
