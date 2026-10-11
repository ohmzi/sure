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
end
