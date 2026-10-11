require "test_helper"

class DocumentLinkTest < ActiveSupport::TestCase
  # assert_enqueued_with lives in ActiveJob::TestHelper (the repo convention —
  # the same include Task 1's finish_processing! enqueue pin needs, see
  # test/models/ofx_import_test.rb and its Ruling M2-L2 note).
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @entry = entries(:transaction)
    @link = document_links(:unlinked_receipt)
  end

  test "STATUSES is the pinned membership" do
    assert_equal %w[queued processing unlinked suggested pending_review linked verified dismissed failed],
                 DocumentLink::STATUSES
  end

  test "link_to_entry! links the row and never touches the entry's money" do
    # Ruling M1 (M1), 2026-10-10 close-out: capture the date BEFORE the call —
    # asserting it against itself (@entry.date == @entry.date) is vacuous.
    date_before = @entry.date
    assert @link.link_to_entry!(@entry, confidence: 88)
    @link.reload
    assert_equal "linked", @link.status
    assert_equal @entry.id, @link.entry_id
    assert_equal 88, @link.confidence

    @entry.reload
    assert_equal 10, @entry.amount
    assert_equal "Starbucks", @entry.name
    assert_equal date_before, @entry.date
  end

  test "unlink! clears the entry AND the confidence" do
    link = document_links(:linked_receipt)
    assert link.unlink!
    link.reload
    assert_equal "unlinked", link.status
    assert_nil link.entry_id
    assert_nil link.confidence
  end

  test "fail! only settles a processing row (guarded transition)" do
    link = document_links(:linked_receipt)
    assert_not link.fail!("late failure")
    link.reload
    assert_equal "linked", link.status
    assert_nil link.failure_message
  end

  test "finish_processing! files the document id and only from processing" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!
    assert link.finish_processing!(document_id: 4242)
    link.reload
    assert_equal "unlinked", link.status
    assert_equal 4242, link.paperless_document_id
    assert_nil link.paperless_task_id
  end

  test "record_match! moves an unlinked row to suggested through the guarded path" do
    assert @link.record_match!(status: "suggested", confidence: 62)
    @link.reload
    assert_equal "suggested", @link.status
    assert_equal 62, @link.confidence
  end

  test "record_match! raises for a status outside MATCHER_OUTCOMES" do
    assert_raises(ArgumentError) { @link.record_match!(status: "linked", confidence: 10) }
    assert_equal "unlinked", @link.reload.status
  end

  test "record_match! refuses a row the user already moved (guard branch)" do
    link = document_links(:linked_receipt)
    assert_not link.record_match!(status: "suggested", confidence: 50)
    link.reload
    assert_equal "linked", link.status
    assert_equal 90, link.confidence
  end

  test "retry_upload! resets the poll budget and clears the failure" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!
    link.note_poll!(7)
    assert link.fail!("boom")
    assert link.retry_upload!
    link.reload
    assert_equal "queued", link.status
    assert_equal 0, link.poll_attempts
    assert_nil link.failure_message
  end

  test "a stale transition on an already-moved row is refused" do
    link = document_links(:linked_receipt)
    assert_not link.transition!(from: "processing", to: "failed")
    assert_equal "linked", link.reload.status
  end

  test "verify! only from linked; dismiss! is remembered" do
    link = document_links(:linked_receipt)
    assert link.verify!
    assert_equal "verified", link.reload.status
    assert_not link.dismiss!
  end

  test "destroying an entry unlinks its documents and clears confidence" do
    link = document_links(:linked_receipt)
    assert_equal 90, link.confidence
    @entry.destroy!
    link.reload
    assert_equal "unlinked", link.status
    assert_nil link.entry_id
    assert_nil link.confidence
  end

  test "for_entry scopes to the entry" do
    assert_includes DocumentLink.for_entry(@entry), document_links(:linked_receipt)
    assert_not_includes DocumentLink.for_entry(@entry), document_links(:unlinked_receipt)
  end

  test "link_from_upload! creates a queued row for the family" do
    link = DocumentLink.link_from_upload!(family: @family, uploader: users(:family_admin), source: "receipt", title: "New")
    assert link.persisted?
    assert_equal "queued", link.status
    assert_equal @family.id, link.family_id
  end

  test "record_content! writes the snapshot once and refuses to overwrite it" do
    link = document_links(:unlinked_receipt)
    assert link.record_content!("COFFEE BAR\nTOTAL 4.75")

    link.reload
    assert_equal "COFFEE BAR\nTOTAL 4.75", link.extracted_text

    assert_not link.record_content!("different text")
    assert_equal "COFFEE BAR\nTOTAL 4.75", link.reload.extracted_text
  end

  test "record_content! truncates very long OCR bodies at the pinned limit" do
    link = document_links(:unlinked_receipt)
    assert link.record_content!("x" * (DocumentLink::EXTRACTED_TEXT_LIMIT + 50))
    assert_equal DocumentLink::EXTRACTED_TEXT_LIMIT, link.reload.extracted_text.length
  end

  test "record_content! writes nothing for blank text" do
    link = document_links(:unlinked_receipt)
    assert_not link.record_content!("")
    assert_nil link.reload.extracted_text
  end

  test "finish_processing! enqueues exactly one content capture when it settles the row" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!

    assert_enqueued_with(job: Paperless::CaptureContentJob, args: [ link.id ]) do
      assert link.finish_processing!(document_id: 4242)
    end

    assert_not link.finish_processing!(document_id: 4243)
  end

  # (Ruling M7-L9, 2026-10-11 close-out) the settle choke point's enqueue is
  # failure-SAFE: a transient enqueue failure (Sidekiq/Redis down) must not
  # lose the snapshot silently (the M1-Ruling-11 class). The settle stands, the
  # failure is logged, and the settled-but-snapshotless scope the backfill task
  # computes — re-driven hourly by SyncCleanerJob — picks the link up.
  test "a raising content-capture enqueue is rescued and the sweep re-drives the link" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!

    Paperless::CaptureContentJob.stubs(:perform_later).raises(StandardError.new("redis down"))

    settled = nil
    assert_difference "DebugLogEntry.count", 1 do
      assert_nothing_raised { settled = link.finish_processing!(document_id: 4242) }
    end
    assert settled, "the settle must stand when only the enqueue failed"

    link.reload
    assert_equal "unlinked", link.status
    assert_equal 4242, link.paperless_document_id
    assert_nil link.extracted_text

    Paperless::CaptureContentJob.unstub(:perform_later)

    assert_enqueued_with(job: Paperless::CaptureContentJob, args: [ link.id ]) do
      DocumentLink.capture_pending_content
    end
  end
end
