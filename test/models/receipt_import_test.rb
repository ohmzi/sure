require "test_helper"

class ReceiptImportTest < ActiveSupport::TestCase
  # assert_enqueued_with lives in ActiveJob::TestHelper (the repo convention —
  # Task 1's recorded deviation: the plan's fences assume the helper is present).
  include ActiveJob::TestHelper
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @link = document_links(:unlinked_receipt)
  end

  test "UNDERSTANDING_STATES is the pinned membership" do
    assert_equal %w[awaiting_ocr understood needs_understanding], ReceiptImport::UNDERSTANDING_STATES
  end

  test "create_from_document_link! builds an awaiting_ocr draft with the receipt signage" do
    draft = ReceiptImport.create_from_document_link!(document_link: @link)

    assert draft.persisted?
    assert_equal "pending", draft.status
    assert_equal "awaiting_ocr", draft.understanding_state
    assert_equal @family.id, draft.family_id
    assert_equal @link.id, draft.document_link_id
    assert_nil draft.account
    assert_equal "inflows_negative", draft.signage_convention
  end

  test "a receipt draft requires a document link and a known understanding state" do
    draft = ReceiptImport.new(family: @family)
    assert_not draft.valid?

    draft.understanding_state = "guessing"
    assert_not draft.valid?
  end

  test "a document link exposes its receipt drafts" do
    assert_includes @link.receipt_imports, imports(:receipt_draft)
  end

  # --- Task 7: the reviewed publish (D8) --------------------------------------

  test "publish creates exactly one expense with the document identity" do
    draft = imports(:receipt_understood)
    draft.update!(understanding_state: "understood")
    # (repaired 2026-10-10, verifier F3) The fixture keeps its items in
    # extracted_data; Import::Row records only exist once the Task-6 row path
    # generates them, and line_items_split? reads rows — generate them exactly
    # as understanding does. (repaired 2026-10-10, round 2: F3) Re-derived
    # under the fixture's signage_convention: inflows_negative (Task 2's
    # fixtures note): the convention makes signed_amount the identity, so the
    # rows sum +4.75 + 7.25 = +12.00, exactly the 12.00 total →
    # line_items_split? true → 2 children + 1 parent.
    draft.generate_rows_from_line_items!
    assert_equal 2, draft.reload.rows_count

    assert_difference -> { Entry.count } => 3, -> { Transaction.count } => 3 do # parent + 2 split children
      draft.publish
    end

    entry = draft.reload.entries.find_by(parent_entry_id: nil)
    # (Task 8) The identity is the DOCUMENT, not paperless_document_id — a
    # column Task 12 deletes. The link id is stable across retries.
    assert_equal "document:#{draft.document_link.id}", entry.external_id
    assert_equal "document", entry.source
    assert_equal BigDecimal("12.00"), entry.amount
    assert_equal Date.new(2026, 9, 14), entry.date
    assert_equal accounts(:depository), entry.account
    assert_equal 2, entry.child_entries.count
  end

  test "a replayed publish never duplicates the entry" do
    draft = imports(:receipt_understood)
    draft.publish
    count = Entry.count
    # (Ruling M7-L3) a completed draft is terminal: never publishable again.
    assert_not draft.reload.publishable?, "a completed draft must not be publishable"

    draft.publish # Import#publish early-returns for a complete import
    assert_equal count, Entry.count
  end

  # (Ruling M7-L3) The writer is replay-safe on its own, not just behind the
  # route: the reviewer's direct-call probe re-ran import! on already-committed
  # data and doubled the split children (2 -> 4). The parent is claimed by its
  # `document:<link id>` external_id (Task 8), so a replay writes nothing.
  test "a direct import! replay on committed data writes nothing" do
    draft = imports(:receipt_understood)
    draft.generate_rows_from_line_items!
    draft.publish

    parent = draft.reload.entries.find_by(parent_entry_id: nil)
    assert_equal 2, parent.child_entries.count

    assert_no_difference [ -> { Entry.count }, -> { Transaction.count } ] do
      draft.import!
    end

    assert_equal 2, parent.reload.child_entries.count
  end

  test "a receipt with item lines that do not sum to the total publishes unsplit" do
    draft = imports(:receipt_understood)
    draft.extracted_data = draft.extracted_data.merge(
      "line_items" => [
        { "description" => "Latte", "amount" => "4.75" },
        { "description" => "Sandwich", "amount" => "5.00" } # 9.75, not the 12.00 total
      ]
    )
    draft.save!
    # (repaired 2026-10-10, verifier F3) Rows must exist for the mismatch to be
    # exercised: two rows that do not sum, so publishing must stay unsplit
    # (exactly one entry — a wrongly-taken split branch would make it three).
    # (repaired 2026-10-10, round 2: F3) With the fixture's inflows_negative
    # signage the signed amounts are the identity: +4.75 + 5.00 = 9.75 ≠ 12.00
    # — the mismatch this test exists for.
    draft.generate_rows_from_line_items!
    assert_equal 2, draft.reload.rows_count

    assert_difference -> { Entry.count } => 1 do
      draft.publish
    end
    assert_equal 1, draft.reload.entries.count
    assert_equal 0, draft.entries.find_by(parent_entry_id: nil).child_entries.count
  end

  test "publishing never claims an existing manual entry" do
    account = accounts(:depository)
    manual = create_transaction(account: account, date: Date.new(2026, 9, 14), amount: 12, name: "Lunch")
    draft = imports(:receipt_understood)

    draft.publish

    manual.reload
    assert_nil manual.external_id, "the manual entry must not be claimed"
    assert_equal BigDecimal("12.00"), draft.reload.total_amount # sanity
    assert_equal 1, draft.entries.where(parent_entry_id: nil).count
  end

  test "needs_understanding accepts a manual total and becomes publishable" do
    draft = imports(:receipt_draft)

    assert draft.apply_manual_details!(total: "18.40", date: "2026-09-20", payee: "Cafe")
    draft.reload
    assert draft.understood?
    assert_equal BigDecimal("18.40"), draft.total_amount
    assert_equal Date.new(2026, 9, 20), draft.purchase_date
  end

  test "a garbage manual total is refused" do
    assert_not imports(:receipt_draft).apply_manual_details!(total: "not money")
  end

  test "the duplicate hint is read-only" do
    create_transaction(account: accounts(:depository), date: Date.new(2026, 9, 14), amount: 12, name: "Lunch")
    draft = imports(:receipt_understood)

    assert draft.duplicate_candidate.present?
    assert_nil draft.duplicate_candidate.external_id
  end

  test "a receipt with a total but no date cannot publish" do
    # (repaired 2026-10-10, verifier F8) Entry validates date presence, so the
    # gate must: a date-less draft is not publishable, and even a forced publish
    # writes no money (import! refuses before the adapter is reached).
    draft = imports(:receipt_understood)
    draft.update!(extracted_data: draft.extracted_data.except("date"))

    assert_not draft.publishable?, "the publish affordance must be off without a date"

    assert_no_difference -> { Entry.count } do
      draft.publish
    end
  end

  # --- Task 8: the receipt seam -----------------------------------------------
  #
  # The identity is the DOCUMENT, not the paperless id — the column this used to
  # read is deleted in Task 12, and if the identity is not re-pointed here a
  # retried publish can no longer find its own entry and the D8 replay-safety
  # property is lost SILENTLY (every pre-Task-8 test still passes). The brief's
  # fence spells the fixture `receipt_imports(:pending_receipt)`; the repo has no
  # such fixture — the awaiting_ocr draft on the unlinked_receipt link is
  # `imports(:receipt_draft)` (the same row the old create_from_document_link!
  # test uses), so that is the one used here.

  test "import! mints an identity that does not depend on paperless" do
    draft = imports(:receipt_draft)
    draft.update!(account: accounts(:depository), extracted_data: {
      "total" => "12.34", "date" => "2026-10-01", "payee" => "Acme", "line_items" => []
    })

    entry = nil
    assert_difference -> { Entry.count }, 1 do
      draft.import!
      entry = draft.reload.document_link.entry
    end

    assert_equal "document:#{draft.document_link.id}", entry.external_id
    assert_equal "document", entry.source
  end

  test "publishing links the document to the entry it created" do
    draft = imports(:receipt_draft)
    draft.update!(account: accounts(:depository), extracted_data: {
      "total" => "12.34", "date" => "2026-10-01", "payee" => "Acme", "line_items" => []
    })

    draft.import!

    assert_equal draft.reload.document_link.reload.entry_id, draft.document_link.entry.id
    assert_equal "linked", draft.document_link.status
  end

  # (Task 8) The brief's name for this case claimed identity dedup, but the
  # second call never reaches the adapter: `data_committed?` (the M7-L3/L8
  # guard, pinned by the tests above) short-circuits it. What this case actually
  # adds is that the guard holds for a FRESH instance — `ReceiptImport.find`
  # re-reads the row rather than reusing the in-memory object that just wrote.
  # Named for what it pins.
  test "a replayed import! on a fresh instance returns at the committed-data guard" do
    draft = imports(:receipt_draft)
    draft.update!(account: accounts(:depository), extracted_data: {
      "total" => "12.34", "date" => "2026-10-01", "payee" => "Acme", "line_items" => []
    })

    draft.import!
    assert_no_difference -> { Entry.count } do
      ReceiptImport.find(draft.id).import!
    end
  end
end

# A genuine concurrent double-submit needs a second, concurrently-committing
# connection to reproduce: with the unlocked `data_committed?` check, the
# second caller read "not committed" while the first was mid-transaction and
# re-ran the writer, doubling the split children (2 -> 4 — the Ruling M7-L8
# close-out finding; the check-then-act race the sequential replay pins cannot
# see). Runs without transactional fixtures so the writer thread's commit is
# visible to the reader's separate connection (the FamilyMerchantConcurrency
# Test precedent in test/models/family_merchant_test.rb).
class ReceiptImportConcurrentPublishTest < ActiveSupport::TestCase
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
  end

  teardown do
    # This class commits (no transactional rollback), so remove exactly what
    # the test wrote before the fixture set is reused. Destroying the parent
    # takes its split children (dependent: :destroy); a child cannot be
    # destroyed on its own (Entry#prevent_individual_child_deletion).
    draft = imports(:receipt_understood)
    draft.entries.where(parent_entry_id: nil).find_each(&:destroy)
    draft.rows.destroy_all
    # (Task 8) import! now calls document_link.link_to_entry!, so the LINK is
    # written too — and this class commits, so the fixture set is reused. Reset
    # it to the fixture's own state (unlinked, no entry) or the next test in
    # this process inherits a linked row pointing at a destroyed entry.
    draft.document_link.unlink!
  ensure
    ActiveRecord::Base.establish_connection(@original_db_config) if @original_db_config
  end

  test "a concurrent double-submit serializes on the draft's row lock and the children stay at 2" do
    draft = imports(:receipt_understood)
    draft.generate_rows_from_line_items!

    writer_entered = Queue.new
    release_writer = Queue.new
    reader_pid = Queue.new

    # The writer runs the real import!; its `line_items_split?` call sits INSIDE
    # the locked section, after the entry write — pausing there parks the
    # writer mid-transaction holding the draft's row lock with an uncommitted
    # parent entry, exactly the window a second submit races.
    writer_draft = ReceiptImport.find(draft.id)
    writer_draft.define_singleton_method(:line_items_split?) do
      writer_entered << true
      release_writer.pop
      super()
    end

    writer = nil
    reader = nil

    begin
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          writer_draft.import!
        end
      end

      writer_entered.pop

      reader = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          reader_pid << connection.select_value("SELECT pg_backend_pid()")

          ReceiptImport.find(draft.id).import!
        end
      end

      pid = reader_pid.pop.to_i

      # Wait until Postgres itself reports the reader blocked on a lock — the
      # writer's SELECT ... FOR UPDATE of the draft row — proving the two
      # submits genuinely overlap. Only then is releasing the writer guaranteed
      # to exercise the serialization rather than a sequential replay.
      deadline = Time.current + 10.seconds
      wait_event_type = nil
      loop do
        wait_event_type = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{pid}"
        )
        break if wait_event_type == "Lock" || Time.current > deadline || !reader.alive?
        sleep 0.01
      end

      unless wait_event_type == "Lock"
        diagnosis = reader.alive? ? "timed out waiting" : "the reader thread already finished (status: #{reader.status.inspect})"
        flunk "reader never blocked on the draft's row lock (wait_event_type=#{wait_event_type.inspect}); #{diagnosis}; the race wasn't reproduced"
      end

      release_writer << true
      writer.value # joins the writer and re-raises anything it raised
      reader.value # likewise; the loser of the race must return, not raise

      # (Task 8) The parent's identity is the DOCUMENT link id — the same
      # `document:<link id>` import! now mints.
      external_id = "document:#{draft.document_link.id}"
      parent = Entry.find_by(account: accounts(:depository), external_id: external_id)
      assert parent.present?, "the first submit must commit the expense"
      assert_equal 2, parent.child_entries.count, "the second submit must not re-mint the split children"
      assert_equal 1, Entry.where(account: accounts(:depository), external_id: external_id).count
      assert_equal 3, draft.entries.reload.count # parent + 2 children, nothing more
    ensure
      # Unblocks the writer even if an assertion above failed, so its thread
      # (and checked-out connection) don't leak past this test.
      release_writer << true
      writer&.join(2)
      reader&.join(2)
    end
  end
end
