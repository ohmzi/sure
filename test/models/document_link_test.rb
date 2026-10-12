require "test_helper"

class DocumentLinkTest < ActiveSupport::TestCase
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

  test "retry_upload! clears the failure and re-queues the row" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!
    assert link.fail!("boom")
    assert link.retry_upload!
    link.reload
    assert_equal "queued", link.status
    assert_nil link.failure_message
  end

  test "reprocess! frees the row for a fresh read without touching the money" do
    link = document_links(:linked_receipt)
    entry_id = link.entry_id

    link.reprocess!

    assert_equal "queued", link.reload.status
    assert_equal entry_id, link.entry_id, "reprocessing a read must not unlink an entry"
  end

  # The reprocess escape hatch's second half (guidance 2): it clears the
  # TERMINAL bits, so a row the read failed on can be read again — the failure
  # message does not survive to mislabel the fresh attempt. The provenance link
  # still must not move.
  test "reprocess! clears the failure message and re-queues a failed row" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!
    assert link.fail!("OCR service unreachable after 8 attempts: boom")

    assert link.reprocess!
    link.reload
    assert_equal "queued", link.status
    assert_nil link.failure_message
    assert_nil link.entry_id
  end

  # Fix round 2, item 1: the retry-backoff park. A transient OCR failure marks
  # the row `queued` with the reason so the sweep leaves it alone for the whole
  # backoff; the scheduled retry still finds it (the job's guard accepts
  # `queued`), and mark_processing! clears the mark when the read restarts — so
  # a crash after the restart is a plain stale `processing` row, not an
  # invisible one.
  test "await_retry! parks a row in queued with the reason, and mark_processing! clears it" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!

    assert link.await_retry!(message: "OCR service unreachable; a retry is scheduled")
    link.reload
    assert_equal "queued", link.status
    assert_equal "OCR service unreachable; a retry is scheduled", link.failure_message

    assert link.mark_processing!
    link.reload
    assert_equal "processing", link.status
    assert_nil link.failure_message, "a restart must clear the backoff mark"
  end

  test "abandon! lands a spent row terminally from queued, where fail! would no-op" do
    link = document_links(:queued_receipt)
    assert link.mark_processing!
    assert link.await_retry!(message: "OCR service unreachable; a retry is scheduled")

    # fail! only moves a `processing` row; the backoff park leaves the row
    # `queued`, so the exhaustion handler must use abandon! or the row is parked
    # forever.
    assert_not link.fail!("too late")
    assert link.abandon!(message: "OCR service unreachable after 8 attempts")
    link.reload
    assert_equal "failed", link.status
    assert_equal "OCR service unreachable after 8 attempts", link.failure_message
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

  # The native-read escape hatch (Task 7): a reprocess after a model or engine
  # change MUST be able to replace a bad snapshot, which the write-once default
  # refuses.
  test "record_content! with refresh: true replaces a snapshot the default refuses" do
    link = document_links(:unlinked_receipt)
    assert link.record_content!("FIRST READ")
    assert_not link.record_content!("SECOND READ")

    assert link.record_content!("SECOND READ", refresh: true)
    assert_equal "SECOND READ", link.reload.extracted_text
  end
end
