require "test_helper"

class OfxImportTest < ActiveSupport::TestCase
  # Ruling M2-L2: the fence calls assert_enqueued_with / perform_enqueued_jobs,
  # which live in ActiveJob::TestHelper (the repo convention - see
  # test/models/pdf_import_test.rb:4); a plain ActiveSupport::TestCase lacks them.
  include ActiveJob::TestHelper

  setup do
    @family  = families(:dylan_family)
    @account = accounts(:depository)
    @import  = OfxImport.create!(family: @family, account: @account)
    @import.update!(raw_file_str: file_fixture("imports/sample.ofx").read)
  end

  test "is a registered Import type" do
    assert_includes Import::TYPES, "OfxImport"
    assert OfxImport.new(family: @family).is_a?(Import)
  end

  test "after_create sets ISO dates and inflows_positive signage" do
    assert_equal "%Y-%m-%d", @import.date_format
    assert_equal "inflows_positive", @import.signage_convention
  end

  test "generates rows from OFX content" do
    @import.generate_rows_from_csv

    assert_equal 3, @import.rows.count
    assert_equal 3, @import.rows_count
    assert_equal [ "GROCERY STORE", "PAYROLL DEPOSIT", "COFFEE SHOP" ], @import.rows.ordered.map(&:name)
  end

  test "stores the statement sign so expenses become positive entries" do
    @import.generate_rows_from_csv
    grocery = @import.rows.ordered.first

    assert_equal "-45.99", grocery.amount
    assert_equal BigDecimal("45.99"), grocery.signed_amount
  end

  test "does not require the CSV mapping workflow" do
    assert_not @import.requires_csv_workflow?
    assert_equal [], @import.mapping_steps
  end

  test "publish creates entries with source ofx" do
    @import.generate_rows_from_csv
    @import.sync_mappings

    @import.publish

    assert @import.reload.complete?
    assert_equal 3, @account.entries.where(import: @import).count
    assert_equal 3, @account.entries.where(source: "ofx").count
  end

  test "entries carry a file+row external id" do
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.publish

    ids = @account.entries.where(source: "ofx").order(:external_id).pluck(:external_id)
    assert_equal ids, ids.uniq
    assert ids.all? { |id| id.start_with?("stmt:#{@import.content_sha256}:") }
  end

  test "publish schedules a family sync and the imported rows reach the materialized history" do
    @import.generate_rows_from_csv
    @import.sync_mappings

    assert_enqueued_with(job: SyncJob) do
      @import.publish
    end

    # Ruling M2-L2: two drains. A blockless perform_enqueued_jobs performs only
    # the jobs queued at call time (activejob 8.1.3.1 `jobs_with` dupes the
    # set); Family::Syncer fans out child account SyncJobs DURING the flush, so
    # a second drain is what actually materializes them. And the fixture
    # account carries a Valuation dated after these 2024 rows, so
    # `account.balance` is anchored by it - the honest assertion is the
    # materialized history on the imported rows' date (spec §13's real claim:
    # the entries are visible to balances).
    perform_enqueued_jobs
    perform_enqueued_jobs

    net = @account.entries.where(import: @import).sum(:amount)
    assert_equal net.abs, @account.balances.find_by(date: Date.new(2024, 10, 17)).end_balance
  end

  test "refuses to import without an account" do
    import = OfxImport.create!(family: @family)
    import.update!(raw_file_str: file_fixture("imports/sample.ofx").read)
    import.generate_rows_from_csv

    assert_raises(RuntimeError) { import.import! }
    assert_equal 0, @account.entries.where(source: "ofx").count
  end

  test "re-importing the same file does not duplicate entries" do
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.publish

    second = OfxImport.create!(family: @family, account: @account)
    second.update!(raw_file_str: file_fixture("imports/sample.ofx").read)
    second.generate_rows_from_csv
    second.sync_mappings
    second.publish

    assert_equal 3, @account.entries.where(source: "ofx").count
  end

  test "does not duplicate a transaction already recorded manually" do
    @account.entries.create!(
      entryable: Transaction.new,
      date: Date.new(2024, 10, 15),
      amount: BigDecimal("45.99"),
      currency: @account.currency,
      name: "Grocery run"
    )

    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.publish

    # Ruling M2-L2: 5 = the depository fixture's 2 pre-existing Transaction
    # entries (entries.yml: Starbucks, "Payment to credit card account") + the
    # manual "Grocery run" + the 2 imported rows (the grocery row is correctly
    # claimed as a duplicate, not re-created).
    assert_equal 5, @account.entries.where(entryable_type: "Transaction").count
    assert_equal 2, @account.entries.where(source: "ofx").count
  end
end
