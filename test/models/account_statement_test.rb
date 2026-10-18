require "test_helper"

class AccountStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "excluding_tombstones drops a statement whose only document was deleted" do
    content = file_fixture("imports/sample_bank_statement.pdf").binread
    statement = AccountStatement.new(
      family: @family, account: @account,
      filename: "statement.pdf", content_type: "application/pdf",
      checksum: SecureRandom.hex, content_sha256: SecureRandom.hex(32), byte_size: content.bytesize,
      period_start_on: Date.new(2026, 6, 1), period_end_on: Date.new(2026, 6, 30)
    )
    statement.original_file.attach(io: StringIO.new(content), filename: "statement.pdf",
                                   content_type: "application/pdf")
    statement.save!

    link = DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                                original_filename: "statement.pdf", content_type: "application/pdf",
                                account_statement: statement)

    assert_includes AccountStatement.excluding_tombstones, statement

    link.soft_delete!

    assert_not_includes AccountStatement.excluding_tombstones, statement
  end

  test "a tombstoned statement does not cover its month" do
    month = Date.new(2026, 5, 1)
    statement = create_statement(account: @account, month: month, content: "tombstoned-coverage")
    link = DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                                original_filename: statement.filename, content_type: statement.content_type,
                                account_statement: statement)

    link.soft_delete!

    coverage = AccountStatement::Coverage.new(@account, start_month: month, end_month: month)
    assert_equal "missing", coverage.months.first.status
  end

  test "a statement is not deletable while its document still backs an unreconciled entry" do
    statement = create_pdf_statement
    entry = entries(:transaction)
    entry.update!(reconciled_at: nil, reconciled_by_statement: nil)
    DocumentLink.create!(family: @family, source: "statement", status: "linked",
                         original_filename: statement.filename, content_type: statement.content_type,
                         account_statement: statement, entry: entry)

    assert_equal :document, statement.reload.deletion_blocker
    assert_not statement.deletable?
  end

  # -- overlap review hint (P1.7) --------------------------------------------

  test "overlap hint flags statements overlapping beyond the boundary day with different balances" do
    first = create_statement_with_period(
      account: @account,
      period_start_on: Date.new(2026, 6, 12),
      period_end_on: Date.new(2026, 7, 10),
      content: "overlap-first"
    )
    first.update!(opening_balance: 1000, closing_balance: 1200)

    second = create_statement_with_period(
      account: @account,
      # Shares July 5-10 with the first statement — not just the boundary day.
      period_start_on: Date.new(2026, 7, 5),
      period_end_on: Date.new(2026, 8, 10),
      content: "overlap-second"
    )
    second.update!(opening_balance: 1100, closing_balance: 1300)

    assert first.overlapping_balance_mismatch?(second)
    assert_includes first.overlapping_balance_mismatches, second
    assert_includes second.overlapping_balance_mismatches, first
  end

  test "overlap hint ignores statements that only share the boundary day" do
    first = create_statement_with_period(
      account: @account,
      period_start_on: Date.new(2026, 6, 12),
      period_end_on: Date.new(2026, 7, 10),
      content: "adjacent-first"
    )
    first.update!(opening_balance: 1000, closing_balance: 1200)

    second = create_statement_with_period(
      account: @account,
      period_start_on: Date.new(2026, 7, 10),
      period_end_on: Date.new(2026, 8, 12),
      content: "adjacent-second"
    )
    second.update!(opening_balance: 1200, closing_balance: 1400)

    assert_not first.overlapping_balance_mismatch?(second)
    assert_empty first.overlapping_balance_mismatches
  end

  test "overlap hint ignores a true overlap whose printed balances agree" do
    first = create_statement_with_period(
      account: @account,
      period_start_on: Date.new(2026, 6, 12),
      period_end_on: Date.new(2026, 7, 10),
      content: "same-balance-first"
    )
    first.update!(opening_balance: 1000, closing_balance: 1200)

    second = create_statement_with_period(
      account: @account,
      period_start_on: Date.new(2026, 7, 5),
      period_end_on: Date.new(2026, 8, 10),
      content: "same-balance-second"
    )
    second.update!(opening_balance: 1000, closing_balance: 1200)

    assert_not first.overlapping_balance_mismatch?(second)
    assert_empty first.overlapping_balance_mismatches
  end

  test "overlap hint stays within the account" do
    other_account = Account.create!(
      family: @family, owner: users(:family_admin), name: "Overlap Other",
      balance: 0, currency: "USD", accountable: Depository.new
    )

    first = create_statement_with_period(
      account: @account,
      period_start_on: Date.new(2026, 6, 12),
      period_end_on: Date.new(2026, 7, 10),
      content: "account-scope-first"
    )
    first.update!(opening_balance: 1000, closing_balance: 1200)

    second = create_statement_with_period(
      account: other_account,
      period_start_on: Date.new(2026, 7, 5),
      period_end_on: Date.new(2026, 8, 10),
      content: "account-scope-second"
    )
    second.update!(opening_balance: 1100, closing_balance: 1300)

    assert_not first.overlapping_balance_mismatch?(second)
    assert_empty first.overlapping_balance_mismatches
  end

  OversizedDeclaredUpload = Struct.new(:original_filename, keyword_init: true) do
    def size
      AccountStatement::MAX_FILE_SIZE + 1
    end

    def read(*)
      raise "oversized upload should be rejected before reading"
    end
  end

  class UploadWithoutDeclaredSize
    attr_reader :original_filename, :content_type

    def initialize(filename:, content_type:, content:)
      @original_filename = filename
      @content_type = content_type
      @io = StringIO.new(content)
    end

    def read(length)
      @io.read(length)
    end

    def rewind
      @io.rewind
    end
  end

  test "creates linked statement from upload without importing transactions" do
    assert_no_difference [ "Import.count", "Entry.count", "Transaction.count" ] do
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(
          filename: "Chase_2024-01_account_6789.csv",
          content_type: "text/csv",
          content: "date,description,amount\n2024-01-01,Coffee,-5.00\n2024-01-31,Deposit,100.00\n"
        )
      )

      assert statement.linked?
      assert_equal @account, statement.account
      assert_equal Date.new(2024, 1, 1), statement.period_start_on
      assert_equal Date.new(2024, 1, 31), statement.period_end_on
      assert_equal "USD", statement.currency
      assert_equal Digest::SHA256.hexdigest("date,description,amount\n2024-01-01,Coffee,-5.00\n2024-01-31,Deposit,100.00\n"), statement.content_sha256
      assert statement.original_file.attached?
    end
  end

  test "suggests obvious account match without linking inbox upload" do
    @account.update!(institution_name: "Chase Bank 6789", notes: "Private note")

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Chase_Bank_2024-01_account_6789.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 statement"
      )
    )

    assert statement.unmatched?
    assert_nil statement.account
    assert_equal @account, statement.suggested_account
    assert_operator statement.match_confidence, :>=, 0.7
  end

  test "rejects duplicate sha256 within family" do
    file_content = "date,description,amount\n2024-01-01,Coffee,-5.00\n"
    AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
    )

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement-copy.csv", content_type: "text/csv", content: file_content)
      )
    end

    assert_equal "statement.csv", error.statement.filename
  end

  test "allows distinct files with same md5 checksum and different sha256" do
    Digest::MD5.stubs(:base64digest).returns("same-md5-checksum")

    assert_difference "AccountStatement.count", 2 do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement-a.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
      )

      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement-b.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
      )
    end
  end

  test "uses md5 checksum fallback for legacy statements without sha256" do
    Digest::MD5.stubs(:base64digest).returns("legacy-md5-checksum")
    existing = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "legacy.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    existing.update_columns(content_sha256: nil)

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "legacy-copy.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
      )
    end

    assert_equal existing, error.statement
  end

  test "reports duplicate upload after database uniqueness race" do
    file_content = "date,description,amount\n2024-01-01,Coffee,-5.00\n"
    existing = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
    )
    prepared_upload = AccountStatement.prepare_upload!(
      uploaded_file(filename: "statement-copy.csv", content_type: "text/csv", content: file_content)
    )

    AccountStatement.stubs(:duplicate_for).returns(nil, existing)
    AccountStatement.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate"))

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      AccountStatement.create_from_prepared_upload!(
        family: @family,
        account: @account,
        prepared_upload: prepared_upload
      )
    end

    assert_equal existing, error.statement
  end

  test "purges staged blob when database uniqueness race is re-raised" do
    prepared_upload = AccountStatement.prepare_upload!(
      uploaded_file(filename: "statement-copy.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    AccountStatement.stubs(:duplicate_for).returns(nil)
    AccountStatement.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate"))

    assert_no_difference [ "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ] do
      assert_raises(ActiveRecord::RecordNotUnique) do
        AccountStatement.create_from_prepared_upload!(
          family: @family,
          account: @account,
          prepared_upload: prepared_upload
        )
      end
    end
  end

  test "purges staged blob when metadata detection fails after attach" do
    AccountStatement::MetadataDetector.any_instance.stubs(:apply).raises(StandardError, "parser failed")

    assert_no_difference [ "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ] do
      assert_raises(StandardError) do
        AccountStatement.create_from_upload!(
          family: @family,
          account: @account,
          file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
        )
      end
    end
  end

  test "with_account scope keeps account linkage semantics while enum predicate follows review status" do
    linked_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    accountless_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(filename: "accountless.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    accountless_statement.update_columns(review_status: "linked")

    assert accountless_statement.reload.linked?
    assert_includes @family.account_statements.with_account, linked_statement
    assert_not_includes @family.account_statements.with_account, accountless_statement
    assert_not_includes @family.account_statements.unmatched, accountless_statement
  end

  test "allows same checksum in different families" do
    file_content = "date,description,amount\n2024-01-01,Coffee,-5.00\n"

    assert_difference "AccountStatement.count", 2 do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
      )

      AccountStatement.create_from_upload!(
        family: families(:empty),
        account: nil,
        file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
      )
    end
  end

  test "validates linked account family" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_not statement.valid?
    assert_includes statement.errors[:account], "is invalid"
  end

  test "validates statement currency codes" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.currency = "NOPE"

    assert_not statement.valid?
    assert_includes statement.errors[:currency], "is invalid"
  end

  test "rejects unsupported file extension even when mime type is broadly allowed" do
    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement.txt", content_type: "text/plain", content: "date,amount\n2024-01-01,1\n")
      )
    end

    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement.xls", content_type: "application/vnd.ms-excel", content: "date,amount\n2024-01-01,1\n")
      )
    end
  end

  test "rejects empty csv and xlsx statement uploads" do
    [
      uploaded_file(filename: "empty.csv", content_type: "text/csv", content: ""),
      uploaded_file(
        filename: "empty.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        content: ""
      )
    ].each do |file|
      assert_no_difference "AccountStatement.count" do
        assert_raises(AccountStatement::InvalidUploadError) do
          AccountStatement.create_from_upload!(family: @family, account: @account, file: file)
        end
      end
    end
  end

  test "rejects declared oversized upload before reading content" do
    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.prepare_upload!(OversizedDeclaredUpload.new(original_filename: "oversized.csv"))
    end
  end

  test "streams unknown-size uploads and rejects when content exceeds size limit" do
    file = UploadWithoutDeclaredSize.new(
      filename: "oversized.csv",
      content_type: "text/csv",
      content: "x" * (AccountStatement::MAX_FILE_SIZE + 1)
    )

    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.prepare_upload!(file)
    end
  end

  test "stores sanitized csv parser output without raw rows" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking_2024-01.csv",
        content_type: "text/csv",
        content: "posted_at,description,amount\n2024-01-01,Coffee Shop,-5.00\n2024-01-31,Payroll,100.00\n"
      )
    )

    assert_equal Date.new(2024, 1, 1), statement.period_start_on
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
    assert_equal "posted_at", statement.sanitized_parser_output.dig("csv", "date_header")
    assert_equal 2, statement.sanitized_parser_output.dig("csv", "rows_sampled")
    assert_not_includes statement.sanitized_parser_output.to_json, "Coffee Shop"
    assert_not_includes statement.sanitized_parser_output.to_json, "Payroll"
  end

  test "detects filename dates separated by underscores" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "statement_2024_01_31.csv",
        content_type: "text/csv",
        content: "description,amount\nCoffee,-5.00\n"
      )
    )

    assert_equal Date.new(2024, 1, 1), statement.period_start_on
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
  end

  test "ignores unreasonable filename dates" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "statement_1969_01_31.csv",
        content_type: "text/csv",
        content: "description,amount\nCoffee,-5.00\n"
      )
    )

    assert_nil statement.period_start_on
    assert_nil statement.period_end_on
  end

  test "samples csv metadata without parsing raw rows into sanitized output" do
    rows = 300.times.map { |index| "2024-01-#{(index % 28) + 1},Row #{index}" }.join("\n")
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking_2024-01.csv",
        content_type: "text/csv",
        content: "posted_at,description\n#{rows}\n"
      )
    )

    assert_equal 250, statement.sanitized_parser_output.dig("csv", "rows_sampled")
    assert_not_includes statement.sanitized_parser_output.to_json, "Row 299"
  end

  test "bounds csv metadata detection column count" do
    headers = [ "posted_at", *101.times.map { |index| "column_#{index}" } ].join(",")
    values = [ "2024-01-01", *101.times.map { "value" } ].join(",")

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking.csv",
        content_type: "text/csv",
        content: "#{headers}\n#{values}\n"
      )
    )

    assert_nil statement.sanitized_parser_output["csv"]
  end

  test "bounds csv metadata detection sample length" do
    oversized_date = "2024-01-01" + ("x" * AccountStatement::MetadataDetector::MAX_CSV_SAMPLE_BYTES)

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking.csv",
        content_type: "text/csv",
        content: "posted_at,description\n#{oversized_date},oversized\n"
      )
    )

    assert_nil statement.sanitized_parser_output["csv"]
    assert_not_includes statement.sanitized_parser_output.to_json, oversized_date
  end

  test "preserves sanitized pdf metadata output" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Statement.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 statement"
      )
    )

    assert_equal "filename_only", statement.sanitized_parser_output["pdf_detection"]
    assert_empty statement.sanitized_parser_output["metadata_sources"]
    assert_nil statement.institution_name_hint
    assert_nil statement.account_name_hint
    assert_equal 0.1.to_d, statement.parser_confidence
  end

  test "stores another bank's pdf statement and reads its period from the text" do
    fixture_path = file_fixture("imports/sample_bank_statement.pdf")
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: Rack::Test::UploadedFile.new(
        fixture_path,
        "application/pdf",
        true,
        original_filename: "sample_bank_statement_2024-01.pdf"
      )
    )

    assert statement.linked?
    assert statement.original_file.attached?
    assert_equal "application/pdf", statement.content_type
    assert_equal fixture_path.size, statement.byte_size
    assert_equal Digest::SHA256.file(fixture_path).hexdigest, statement.content_sha256
    # An M-PESA statement: "Statement Period: 01st 1 2025 - 01st 7 2025" wins
    # over the filename date, and it has no opening or closing balance.
    assert_equal "text", statement.sanitized_parser_output["pdf_detection"]
    assert_equal Date.new(2025, 1, 1), statement.period_start_on
    assert_equal Date.new(2025, 7, 1), statement.period_end_on
    assert_nil statement.opening_balance
    assert_nil statement.closing_balance
    assert_equal false, statement.sanitized_parser_output.dig("pdf", "balances_detected")
    assert statement.original_file.blob.download.start_with?("%PDF-")
  end

  test "reads period and balances from a Trade Republic statement pdf over a filename date" do
    eur_account = @family.accounts.create!(
      name: "Trade Republic Cash",
      balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )
    fixture_path = file_fixture("account_statements/trade_republic_it_2026_04.pdf")

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: eur_account,
      file: Rack::Test::UploadedFile.new(
        fixture_path,
        "application/pdf",
        true,
        original_filename: "Trade Republic 2026-03.pdf"
      )
    )

    assert_equal Date.new(2026, 4, 1), statement.period_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_end_on
    assert_equal BigDecimal("1101.14"), statement.opening_balance
    assert_equal BigDecimal("11948.59"), statement.closing_balance
    assert_equal "1234", statement.account_last4_hint
    assert_equal "Trade Republic", statement.institution_name_hint
    assert_equal "text", statement.sanitized_parser_output["pdf_detection"]
    assert_equal "summary_table", statement.sanitized_parser_output.dig("pdf", "balances_source")
    assert_equal [ "pdf_text", "filename" ], statement.sanitized_parser_output["metadata_sources"]
    assert_equal 0.85.to_d, statement.parser_confidence
    assert_not_includes statement.sanitized_parser_output.to_json, "MARIO ROSSI"
  end

  test "reads a Trade Republic statement saved under its default filename" do
    eur_account = @family.accounts.create!(
      name: "Trade Republic Cash",
      balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: eur_account,
      file: Rack::Test::UploadedFile.new(
        file_fixture("account_statements/trade_republic_it_2026_04.pdf"),
        "application/pdf",
        true,
        original_filename: "Account statement.pdf"
      )
    )

    assert_equal Date.new(2026, 4, 1), statement.period_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_end_on
    assert_equal BigDecimal("11948.59"), statement.closing_balance
    assert_nil statement.institution_name_hint
    assert_nil statement.account_name_hint
    assert_equal [ "pdf_text" ], statement.sanitized_parser_output["metadata_sources"]
  end

  test "skips Trade Republic balances when the statement currency differs" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: Rack::Test::UploadedFile.new(
        file_fixture("account_statements/trade_republic_it_2026_04.pdf"),
        "application/pdf",
        true,
        original_filename: "statement.pdf"
      )
    )

    assert_equal "USD", statement.currency
    assert_equal Date.new(2026, 4, 1), statement.period_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_end_on
    assert_nil statement.opening_balance
    assert_nil statement.closing_balance
    assert_equal false, statement.sanitized_parser_output.dig("pdf", "balances_detected")
    assert_nil statement.sanitized_parser_output.dig("pdf", "balances_source")
  end

  test "does not read a bare MM-YYYY token in the filename as the period" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Invoice_04-2029.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 statement"
      )
    )

    assert_nil statement.period_start_on
    assert_nil statement.period_end_on
  end

  test "handles malformed csv metadata detection without raw parser output" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Unknown 2024-02.csv",
        content_type: "text/csv",
        content: "date,description\n\"unterminated"
      )
    )

    assert_equal Date.new(2024, 2, 1), statement.period_start_on
    assert_equal Date.new(2024, 2, 29), statement.period_end_on
    assert_nil statement.sanitized_parser_output["csv"]
    assert_not_includes statement.sanitized_parser_output.to_json, "unterminated"
  end

  test "reports reconciliation unavailable when balances are missing" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(
      period_start_on: Date.new(2024, 1, 1),
      period_end_on: Date.new(2024, 1, 31),
      closing_balance: 100
    )

    assert_empty statement.reconciliation_checks
    assert_equal "unavailable", statement.reconciliation_status
  end

  test "coverage requires account" do
    error = assert_raises(ArgumentError) do
      AccountStatement::Coverage.new(nil)
    end
    assert_match(/account is required/, error.message)
  end

  test "database constraints reject invalid persisted status values" do
    attrs = {
      family_id: @family.id,
      filename: "statement.csv",
      content_type: "text/csv",
      byte_size: 1,
      checksum: SecureRandom.base64(16),
      source: "provider_sync",
      upload_status: "stored",
      review_status: "unmatched"
    }

    assert_raises(ActiveRecord::StatementInvalid) do
      AccountStatement.transaction(requires_new: true) do
        AccountStatement.insert_all!([ attrs ], record_timestamps: true)
      end
    end
  end

  test "database constraints reject empty persisted statement byte sizes" do
    attrs = {
      family_id: @family.id,
      filename: "empty.csv",
      content_type: "text/csv",
      byte_size: 0,
      checksum: SecureRandom.base64(16),
      source: "manual_upload",
      upload_status: "stored",
      review_status: "unmatched"
    }

    assert_raises(ActiveRecord::StatementInvalid) do
      AccountStatement.transaction(requires_new: true) do
        AccountStatement.insert_all!([ attrs ], record_timestamps: true)
      end
    end
  end

  test "moves linked statements to inbox when account is deleted" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Temporary Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    account.destroy!

    statement.reload
    assert_nil statement.account
    assert statement.unmatched?
    assert_includes @family.account_statements.unmatched, statement
  end

  test "unlink clears invalid recomputed suggestion" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    other_account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    invalid_match = AccountStatement::AccountMatcher::Match.new(account: other_account, confidence: 0.9)
    AccountStatement::AccountMatcher.any_instance.stubs(:best_match).returns(invalid_match)

    statement.unlink!

    statement.reload
    assert_nil statement.account
    assert_nil statement.suggested_account
    assert_nil statement.match_confidence
    assert statement.unmatched?
  end

  test "preserves explicit rejected review status" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.reject_match!

    assert statement.rejected?
    assert_equal @account, statement.account
  end

  test "preserves rejected review status across unrelated saves" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.reject_match!

    statement.update!(period_start_on: Date.new(2024, 1, 1))

    assert statement.rejected?
    assert_equal @account, statement.account
  end

  test "allows intentional review status changes away from rejected" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.reject_match!

    statement.link_to_account!(@account)

    assert statement.linked?
    assert_equal @account, statement.account
  end

  test "normalizes account last four hint when matching accounts" do
    @account.update!(institution_name: "Acme Bank ABCD", notes: "Private note")

    statement = AccountStatement.new(
      family: @family,
      institution_name_hint: "Acme",
      account_last4_hint: "ABCD",
      currency: @account.currency
    )

    match = AccountStatement::AccountMatcher.new(statement).best_match

    assert_equal @account, match.account
    assert_operator match.confidence, :>=, 0.75.to_d
  end

  test "does not match account last four hints from account notes" do
    @account.update!(institution_name: "Acme Bank", notes: "Masked statement suffix abcd")

    statement = AccountStatement.new(
      family: @family,
      account_last4_hint: "ABCD",
      currency: @account.currency
    )

    assert_nil AccountStatement::AccountMatcher.new(statement).best_match
  end

  test "needs_account? is true only for an account-less, not-rejected statement" do
    linked = AccountStatement.create_from_upload!(
      family: @family, account: @account,
      file: uploaded_file(filename: "na_linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    assert_not linked.needs_account?

    unmatched = AccountStatement.create_from_upload!(
      family: @family, account: nil,
      file: uploaded_file(filename: "na_unmatched.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,2\n")
    )
    assert unmatched.needs_account?

    unmatched.reject_match!
    assert_not unmatched.needs_account?, "a rejected match is not waiting on a person"
  end

  test "coverage year selection spans historical account data through last completed month" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Historical Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    travel_to Date.new(2026, 5, 6) do
      create_statement(account: account, month: Date.new(2024, 2, 1), content: "historical")

      current_year_coverage = AccountStatement::Coverage.for_year(account, nil)
      historical_coverage = AccountStatement::Coverage.for_year(account, 2024)

      assert_equal 2026, current_year_coverage.selected_year
      assert_equal [ 2026, 2025, 2024 ], current_year_coverage.available_years

      historical_statuses = historical_coverage.months.index_by(&:date).transform_values(&:status)
      assert_equal "not_expected", historical_statuses[Date.new(2024, 1, 1)]
      assert_equal "covered", historical_statuses[Date.new(2024, 2, 1)]
      assert_equal "missing", historical_statuses[Date.new(2024, 3, 1)]

      current_statuses = current_year_coverage.months.index_by(&:date).transform_values(&:status)
      assert_equal "missing", current_statuses[Date.new(2026, 4, 1)]
      assert_equal "not_expected", current_statuses[Date.new(2026, 5, 1)]
    end
  end

  test "coverage start can come from balances entries and suggested statements" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Archive Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    account.entries.create!(
      name: "Old transaction",
      date: Date.new(2021, 6, 15),
      amount: 10,
      currency: "USD",
      entryable: Transaction.new
    )
    account.balances.create!(date: Date.new(2020, 3, 31), balance: 100, currency: "USD")
    create_statement(account: nil, suggested_account: account, month: Date.new(2019, 7, 1), content: "suggested")

    travel_to Date.new(2026, 5, 6) do
      coverage = AccountStatement::Coverage.for_year(account, 2019)
      statuses = coverage.months.index_by(&:date).transform_values(&:status)

      assert_equal [ 2026, 2025, 2024, 2023, 2022, 2021, 2020, 2019 ], coverage.available_years
      assert_equal "not_expected", statuses[Date.new(2019, 6, 1)]
      assert_equal "ambiguous", statuses[Date.new(2019, 7, 1)]
    end
  end

  test "coverage marks covered duplicate ambiguous and mismatched months" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Coverage Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    covered_month = 5.months.ago.to_date.beginning_of_month
    missing_month = 4.months.ago.to_date.beginning_of_month
    duplicate_month = 3.months.ago.to_date.beginning_of_month
    ambiguous_month = 2.months.ago.to_date.beginning_of_month
    mismatched_month = 1.month.ago.to_date.beginning_of_month

    create_statement(account: account, month: covered_month, content: "covered")
    create_statement(account: account, month: duplicate_month, content: "duplicate-a")
    create_statement(account: account, month: duplicate_month, content: "duplicate-b")
    create_statement(account: nil, suggested_account: account, month: ambiguous_month, content: "ambiguous")
    create_statement(account: account, month: mismatched_month, content: "mismatched", closing_balance: 120)

    account.balances.create!(
      date: mismatched_month.end_of_month,
      balance: 100,
      currency: "USD",
      start_cash_balance: 100,
      cash_inflows: 0,
      cash_outflows: 0
    )

    coverage = AccountStatement::Coverage.new(
      account,
      start_month: covered_month,
      end_month: mismatched_month
    )

    statuses = coverage.months.index_by(&:date).transform_values(&:status)
    assert_equal "covered", statuses[covered_month]
    assert_equal "missing", statuses[missing_month]
    assert_equal "duplicate", statuses[duplicate_month]
    assert_equal "ambiguous", statuses[ambiguous_month]
    assert_equal "mismatched", statuses[mismatched_month]
  end

  test "coverage does not mark adjacent statements as duplicate when they only share a calendar month" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Adjacent Statement Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    march = Date.new(2026, 3, 1)

    create_statement_with_period(
      account: account,
      period_start_on: Date.new(2026, 1, 8),
      period_end_on: Date.new(2026, 3, 6),
      content: "adjacent-a"
    )

    create_statement_with_period(
      account: account,
      period_start_on: Date.new(2026, 3, 7),
      period_end_on: Date.new(2026, 4, 7),
      content: "adjacent-b"
    )

    coverage = AccountStatement::Coverage.new(
      account,
      start_month: march,
      end_month: march
    )

    assert_equal "covered", coverage.months.first.status
  end

  test "defaults to not_attempted extraction state" do
    statement = create_pdf_statement

    assert statement.not_attempted?
  end

  test "records the extraction_failed extraction state" do
    statement = create_pdf_statement

    statement.update!(extraction_state: :extraction_failed)
    assert statement.reload.extraction_failed?
  end

  test "the extraction_state column is non-null and defaults to not_attempted in the database" do
    # (Ruling M2-C8, 2026-10-11 close-out): the enum default masks the column's
    # own default/null contract, so pin the migration's guarantee directly.
    column = AccountStatement.columns_hash.fetch("extraction_state")

    assert_equal "not_attempted", column.default
    assert_equal false, column.null
  end

  test "a camera photo of a statement is a legal vault upload" do
    prepared = AccountStatement.prepare_upload!(
      Rack::Test::UploadedFile.new(file_fixture("statements/scan.png"), "image/png")
    )
    assert_equal "image/png", prepared.content_type
  end

  test "a jpg camera photo is a legal vault upload too" do
    # The Files block's scan.jpg fixture (M7 Task 8); the map's .jpg entry is
    # the whole difference from the png case, so pin it directly.
    prepared = AccountStatement.prepare_upload!(
      Rack::Test::UploadedFile.new(file_fixture("statements/scan.jpg"), "image/jpeg")
    )
    assert_equal "image/jpeg", prepared.content_type
  end

  test "heic and heif are accepted with the types Task 1 probed" do
    assert_includes AccountStatement::ALLOWED_EXTENSION_CONTENT_TYPES.keys, ".heic"
    assert_equal [ "image/heic" ], AccountStatement::ALLOWED_EXTENSION_CONTENT_TYPES[".heic"]
    assert_equal [ "image/heif" ], AccountStatement::ALLOWED_EXTENSION_CONTENT_TYPES[".heif"]
  end

  # -- data-quality guardrails (P1.11) ---------------------------------------

  test "records the printed period beside the stored period" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: Rack::Test::UploadedFile.new(
        file_fixture("imports/sample_bank_statement.pdf"),
        "application/pdf",
        true,
        original_filename: "sample_bank_statement_2024-01.pdf"
      )
    )

    assert_equal(
      { "start_on" => "2025-01-01", "end_on" => "2025-07-01", "source" => "pdf_text" },
      statement.sanitized_parser_output["detected_period"]
    )
    # The printed period won the stored dates; the filename disagrees, and the
    # disagreement is surfaced instead of silently rewriting either one.
    assert_equal :filename, statement.period_warning.source
    assert statement.period_looks_wrong?
  end

  test "missing_period finds a statement whose stored period is incomplete" do
    statement = create_statement(account: @account, month: Date.new(2026, 5, 1), content: "missing-period")
    statement.update_columns(period_start_on: nil)

    assert_includes AccountStatement.missing_period, statement
    assert statement.missing_period?
  end

  test "missing_printed_identity ignores hints and printed card numbers" do
    anonymous = create_statement(account: @account, month: Date.new(2026, 5, 1), content: "anonymous")
    anonymous.update_columns(account_last4_hint: nil, institution_name_hint: nil, account_name_hint: nil)
    anonymous.update_columns(sanitized_parser_output: {})

    hinted = create_statement(account: @account, month: Date.new(2026, 5, 1), content: "hinted")
    hinted.update_columns(institution_name_hint: "RBC")

    printed = create_statement(account: @account, month: Date.new(2026, 5, 1), content: "printed")
    printed.update_columns(account_last4_hint: nil, institution_name_hint: nil, account_name_hint: nil)
    printed.update_columns(sanitized_parser_output: { "printed_last4s" => %w[1234] })

    assert_includes AccountStatement.missing_printed_identity, anonymous
    assert_not_includes AccountStatement.missing_printed_identity, hinted
    assert_not_includes AccountStatement.missing_printed_identity, printed
  end

  test "a mismatched reconciliation check explains its expected and actual figures" do
    card = accounts(:credit_card)
    statement = card_statement(card, Date.new(2026, 5, 9), 100, 130, [ [ Date.new(2026, 5, 20), 25 ] ])

    check = statement.reconciliation_checks.find { |candidate| candidate[:key] == "period_movement" }

    assert_equal "mismatched", check[:status]
    assert check[:explanation].present?
    assert_includes check[:explanation], "$30.00"
    assert_includes check[:explanation], "$25.00"
    assert_includes check[:explanation], "$5.00"
  end

  test "a matched reconciliation check carries no explanation" do
    card = accounts(:credit_card)
    statement = card_statement(card, Date.new(2026, 5, 9), 100, 130, [ [ Date.new(2026, 5, 20), 30 ] ])

    check = statement.reconciliation_checks.find { |candidate| candidate[:key] == "period_movement" }

    assert_equal "matched", check[:status]
    assert_nil check[:explanation]
  end

  private

    def create_pdf_statement
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: Rack::Test::UploadedFile.new(
          file_fixture("imports/sample_bank_statement.pdf"),
          "application/pdf",
          true,
          original_filename: "statement.pdf"
        )
      )
    end

    def create_statement(account:, month:, content:, suggested_account: nil, closing_balance: nil)
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(
          filename: "statement_#{content}_#{month.strftime('%Y-%m')}.csv",
          content_type: "text/csv",
          content: "date,amount\n#{month},1\n#{month.end_of_month},2\n#{content}\n"
        )
      )
      statement.update!(
        suggested_account: suggested_account,
        period_start_on: month,
        period_end_on: month.end_of_month,
        closing_balance: closing_balance
      )
      statement
    end

    def create_statement_with_period(account:, period_start_on:, period_end_on:, content:, suggested_account: nil)
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(
          filename: "statement_#{content}_#{period_start_on}_#{period_end_on}.csv",
          content_type: "text/csv",
          content: "date,amount\n#{period_start_on},1\n#{period_end_on},2\n#{content}\n"
        )
      )

      statement.update!(
        suggested_account: suggested_account,
        period_start_on: period_start_on,
        period_end_on: period_end_on
      )

      statement
    end

    # The owner's choice (2026-10-16): card rows keep their PURCHASE date, so a
    # purchase made before a statement's period (posted inside it) sits on the
    # previous month's side of the boundary. A statement whose rows are in Sure is
    # therefore verified by its own rows — opening + rows = closing — and chained
    # to its neighbours, never by daily balances at the boundary.
    def card_statement(account, start_on, opening, closing, rows)
      s = AccountStatement.create_from_upload!(
        family: account.family, account: account,
        file: Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4 #{start_on} #{SecureRandom.hex(4)}"), "application/pdf", original_filename: "#{start_on}.pdf")
      )
      s.update!(period_start_on: start_on, period_end_on: start_on + 29, opening_balance: opening, closing_balance: closing)
      rows.each do |date, amount|
        account.entries.create!(date: date, amount: amount, name: "row", currency: account.currency,
                                entryable: Transaction.new, reconciled_at: Time.current, reconciled_by_statement_id: s.id)
      end
      s
    end

    def statuses(statement) = statement.reconciliation_checks.to_h { |check| [ check[:key], check[:status] ] }

    test "a card statement is verified by its own rows, a boundary purchase included" do
      card = families(:dylan_family).accounts.create!(name: "Fresh card", balance: 0, currency: "USD", accountable: CreditCard.new)
      # Purchases raise a card's balance, payments lower it; one purchase is dated
      # the day before the period it was posted in.
      june = card_statement(card, Date.new(2026, 5, 9), 100, 130, [ [ Date.new(2026, 5, 8), 40 ], [ Date.new(2026, 5, 20), -10 ] ])
      july = card_statement(card, Date.new(2026, 6, 8), 130, 150, [ [ Date.new(2026, 6, 15), 20 ] ])
      StatementBalanceAnchor.call(june) # what posting the earliest statement does

      assert_equal({ "opening_balance" => "matched", "closing_balance" => "matched", "period_movement" => "matched" }, statuses(june))
      assert_equal "matched", statuses(july)["opening_balance"], "july opens where june closed"
    end

    test "a chequing statement's withdrawals lower and deposits raise its balance" do
      chequing = accounts(:depository)
      statement = card_statement(chequing, Date.new(2026, 5, 12), 100, 130, [ [ Date.new(2026, 5, 13), 20 ], [ Date.new(2026, 5, 14), -50 ] ])

      assert_equal "matched", statuses(statement)["period_movement"]
    end

    test "rows that do not add up to the printed movement are a mismatch" do
      card = accounts(:credit_card)
      statement = card_statement(card, Date.new(2026, 5, 9), 100, 130, [ [ Date.new(2026, 5, 20), 25 ] ])

      assert_equal "mismatched", statuses(statement)["period_movement"]
    end

    test "a statement whose opening disagrees with the previous closing is a mismatch" do
      card = accounts(:credit_card)
      card_statement(card, Date.new(2026, 5, 9), 100, 130, [ [ Date.new(2026, 5, 20), 30 ] ])
      july = card_statement(card, Date.new(2026, 6, 8), 125, 145, [ [ Date.new(2026, 6, 15), 20 ] ])

      assert_equal "mismatched", statuses(july)["opening_balance"]
    end

    # Found live on the owner's RBC statements: one statement ends on the day the
    # next begins (May 12 – Jun 12, then Jun 12 – Jul 10).
    test "a statement that starts on the day the previous one ended chains to it" do
      chequing = families(:dylan_family).accounts.create!(name: "Shared-day chequing", balance: 0, currency: "CAD", accountable: Depository.new)
      june = card_statement(chequing, Date.new(2026, 5, 12), 100, 130, [ [ Date.new(2026, 5, 20), -30 ] ])
      june.update!(period_end_on: Date.new(2026, 6, 12))
      july = card_statement(chequing, Date.new(2026, 6, 12), 130, 150, [ [ Date.new(2026, 6, 20), -20 ] ])

      assert_equal "matched", statuses(july)["opening_balance"]
    end

    # Live on the owner's RBC chequing account: the boundary day's fee is already
    # in the previous statement, so the day OPENS at 94.22 and CLOSES at 81.27.
    # The statement opens where the previous one closed — the end of that day,
    # never its start. Using start_balance reported a false mismatch.
    test "a statement without rows checks its opening against the end of the boundary day" do
      account = accounts(:depository)
      # The premise is a preceding statement ending ON the boundary day. Without
      # it the balance record's start-of-day figure is the only available anchor.
      previous = create_statement_with_period(
        account: account,
        period_start_on: Date.new(2026, 4, 12),
        period_end_on: Date.new(2026, 5, 12),
        content: "boundary-prev"
      )
      previous.update!(opening_balance: 94.22, closing_balance: 81.27)

      statement = AccountStatement.create_from_upload!(
        family: @family, account: account,
        file: uploaded_file(
          filename: "boundary_2026-05-12_2026-06-12.csv",
          content_type: "text/csv",
          content: "date,amount\n2026-05-12,1\n2026-06-12,2\n"
        )
      )
      statement.update!(
        period_start_on: Date.new(2026, 5, 12),
        period_end_on: Date.new(2026, 6, 12),
        opening_balance: 81.27,
        closing_balance: 1550.58
      )
      account.balances.create!(
        date: Date.new(2026, 5, 12), balance: 81.27, currency: account.currency,
        start_cash_balance: 94.22, cash_outflows: 12.95
      )
      account.balances.create!(
        date: Date.new(2026, 6, 12), balance: 1550.58, currency: account.currency,
        start_cash_balance: 1263.53, cash_inflows: 300, cash_outflows: 12.95
      )

      checks = statuses(statement)
      assert_equal "matched", checks["opening_balance"]
      assert_equal "matched", checks["period_movement"]
    end

    # The other layout: April 13 – May 12, then May 13 – June 12. The second
    # statement opens at the START of May 13, which equals the previous
    # statement's close, not the end of May 13 (that day's activity belongs to
    # the new statement).
    test "a statement opening the day after the previous one ended chains to its closing" do
      account = families(:dylan_family).accounts.create!(
        name: "Day-before chequing", balance: 0, currency: "USD", accountable: Depository.new
      )
      previous = create_statement_with_period(
        account: account,
        period_start_on: Date.new(2026, 4, 13),
        period_end_on: Date.new(2026, 5, 12),
        content: "day-before-prev"
      )
      previous.update!(opening_balance: 50, closing_balance: 81.27)

      statement = create_statement_with_period(
        account: account,
        period_start_on: Date.new(2026, 5, 13),
        period_end_on: Date.new(2026, 6, 12),
        content: "day-before-next"
      )
      statement.update!(opening_balance: 81.27, closing_balance: 100)
      account.balances.create!(
        date: Date.new(2026, 5, 13), balance: 60, currency: account.currency,
        start_cash_balance: 81.27, cash_outflows: 21.27
      )
      account.balances.create!(
        date: Date.new(2026, 6, 12), balance: 100, currency: account.currency,
        start_cash_balance: 81.27, cash_inflows: 18.73
      )

      checks = statuses(statement)
      assert_equal "matched", checks["opening_balance"],
                   "the opening is the previous statement's close, not the end of the new statement's first day"
      assert_equal "matched", checks["period_movement"]
    end

    test "a genuinely wrong opening still mismatches in the day-before layout" do
      account = families(:dylan_family).accounts.create!(
        name: "Wrong opening chequing", balance: 0, currency: "USD", accountable: Depository.new
      )
      previous = create_statement_with_period(
        account: account,
        period_start_on: Date.new(2026, 4, 13),
        period_end_on: Date.new(2026, 5, 12),
        content: "wrong-opening-prev"
      )
      previous.update!(opening_balance: 50, closing_balance: 81.27)

      statement = create_statement_with_period(
        account: account,
        period_start_on: Date.new(2026, 5, 13),
        period_end_on: Date.new(2026, 6, 12),
        content: "wrong-opening-next"
      )
      statement.update!(opening_balance: 79, closing_balance: 100)
      account.balances.create!(
        date: Date.new(2026, 5, 13), balance: 60, currency: account.currency,
        start_cash_balance: 81.27, cash_outflows: 21.27
      )
      account.balances.create!(
        date: Date.new(2026, 6, 12), balance: 100, currency: account.currency,
        start_cash_balance: 81.27, cash_inflows: 18.73
      )

      assert_equal "mismatched", statuses(statement)["opening_balance"]
    end

    # Re-downloading a statement changes its PDF metadata, so the same statement
    # arrives with a different SHA-256. Period + account (or last4) is the
    # statement's identity; the bytes are not.
    test "re-uploading the same statement with different bytes is a duplicate" do
      upload = ->(marker) do
        AccountStatement.create_from_upload!(
          family: @family,
          account: @account,
          file: uploaded_file(
            filename: "statement-account-1512-2026-05-09-to-2026-06-08.pdf",
            content_type: "application/pdf",
            content: "%PDF-1.4 #{marker}"
          )
        )
      end

      first = upload.call("first")
      assert_equal Date.new(2026, 5, 9), first.period_start_on
      assert_equal Date.new(2026, 6, 8), first.period_end_on
      assert_equal "1512", first.account_last4_hint

      duplicate = assert_raises(AccountStatement::DuplicateUploadError) { upload.call("second") }
      assert_equal first, duplicate.statement
      assert_equal 1, @family.account_statements
        .where(period_start_on: Date.new(2026, 5, 9), period_end_on: Date.new(2026, 6, 8)).count
    end

    test "coverage counts a statement that ends in the current month" do
      account = families(:dylan_family).accounts.create!(
        name: "Current Month Coverage", balance: 0, currency: "USD", accountable: Depository.new
      )
      create_statement_with_period(
        account: account,
        period_start_on: Date.new(2026, 9, 9),
        period_end_on: Date.new(2026, 10, 8),
        content: "current-month"
      )

      travel_to Date.new(2026, 10, 17) do
        coverage = AccountStatement::Coverage.new(
          account,
          start_month: Date.new(2026, 10, 1),
          end_month: Date.new(2026, 12, 1),
          expected_end_month: Date.new(2026, 9, 1)
        )

        assert_equal "covered", coverage.months.index_by(&:date)[Date.new(2026, 10, 1)].status
      end
    end

    test "a deleted archived document link can be restored" do
      store = Pathname.new(Dir.mktmpdir("statement-link"))
      previous = ENV["SURE_DOCUMENT_STORE_DIR"]
      ENV["SURE_DOCUMENT_STORE_DIR"] = store.to_s

      statement = create_pdf_statement
      first = statement.archive_document_link!
      assert first.present?

      first.soft_delete!
      statement.reload
      assert_nil statement.archived_document_link

      restored = statement.archive_document_link!
      assert_not_equal first.id, restored.id
      assert_equal statement.id, restored.account_statement_id
      assert_nil restored.deleted_at
    ensure
      ENV["SURE_DOCUMENT_STORE_DIR"] = previous
      FileUtils.remove_entry(store) if store&.exist?
    end
end
