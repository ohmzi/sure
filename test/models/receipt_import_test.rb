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

  test "capturing content kicks the linked draft" do
    Paperless::Client.any_instance.stubs(:document).returns(
      Paperless::Document.new(id: 9001, title: "Receipt", created: Date.current, tag_ids: [], content: "TOTAL 1.00")
    )

    assert_enqueued_with(job: ReceiptImport::UnderstandJob, args: [ imports(:receipt_draft).id ]) do
      Paperless::CaptureContentJob.perform_now(document_links(:unlinked_receipt).id)
    end
  end

  # --- Task 7: the reviewed publish (D8) --------------------------------------

  test "publish creates exactly one expense with the reserved paperless external id" do
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
    assert_equal "paperless:#{draft.document_link.paperless_document_id}", entry.external_id
    assert_equal "paperless", entry.source
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
  # `paperless:<docID>` external_id, so a replay writes nothing.
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
end
