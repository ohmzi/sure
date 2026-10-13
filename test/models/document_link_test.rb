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

  # -- the design's "needs you" scope (Milestone B, design D5) ----------------

  test "needs_attention covers a document the reader could not finish" do
    family = families(:dylan_family)
    held = DocumentLink.create!(family: family, source: "other", status: "queued",
                                original_filename: "x.pdf", failure_message: "no AI provider is configured")
    settled = DocumentLink.create!(family: family, source: "receipt", status: "unlinked",
                                   original_filename: "y.jpg")

    scope = DocumentLink.needs_attention(family)

    assert_includes scope, held
    assert_not_includes scope, settled
  end

  test "needs_attention also covers a draft that settled ready to review" do
    # The second branch: a ReceiptImport that reached `understood` but was never
    # published is exactly what pending_review_count_for counts — the same
    # documents the strip offers to show.
    family = families(:dylan_family)
    ready = document_links(:understood_receipt_link)

    assert_includes DocumentLink.needs_attention(family), ready
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

  # -- delete-block and tombstone (spec N9) ----------------------------------
  #
  # Money is never silently cascaded, and a document's provenance is never
  # silently lost. The delete is refused while anything derived is unreconciled;
  # when it is clear, the BYTES go and the ROW stays, so the entry it produced
  # still tells the truth about where it came from.

  test "derived_entries reaches an entry through its draft's document link" do
    # The PRODUCED route: an entry a draft made hangs off
    # `entries.import_id -> imports.document_link_id`. Guarding only the
    # matched-link route would let a delete cascade over money this document
    # created.
    entry = entries(:transaction_entry)
    entry.update!(import: imports(:receipt_understood), reconciled_at: nil)
    link = document_links(:understood_receipt_link)

    assert_includes link.derived_entries, entry
    assert_not link.deletable?
  end

  test "derived_entries reaches an entry the document was only matched to" do
    # The CORROBORATED route: a document the matcher attached to an existing
    # entry hangs off `document_links.entry_id`. Missing this route would orphan
    # a corroboration on delete.
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: nil)

    assert_includes link.derived_entries, link.entry
    assert_not link.deletable?
  end

  test "a document with an unreconciled derived entry refuses to be deleted" do
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: nil)

    assert_not link.deletable?
    assert link.deletion_blockers.any?, "the blocker must name what is in the way, not just be true"
  end

  test "the refusal NAMES the entry that is in the way" do
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: nil)

    assert_equal [ "Starbucks" ], link.deletion_blockers
  end

  test "a document whose derived entries are all reconciled can be deleted" do
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: Time.current)

    assert link.deletable?
    assert_empty link.deletion_blockers
  end

  test "soft_delete! refuses while a derived entry is unreconciled" do
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: nil)

    assert_raises(RuntimeError) { link.soft_delete! }
    assert_nil link.reload.deleted_at, "a refused delete writes nothing"
  end

  test "a soft-deleted document keeps telling the ledger where the entry came from" do
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: Time.current)
    entry = link.entry

    link.soft_delete!

    assert_not_nil link.reload.deleted_at
    assert_equal "document", EntryProvenance.for(entry.reload).primary,
                 "the entry must not silently become 'manual'"
    assert EntryProvenance.for(entry).source_deleted?
  end

  test "a soft-deleted document releases its bytes' digest claim" do
    # The digest is the claim "these bytes are mine". A document that has given
    # up its bytes must give up that claim, or re-adding the identical file is
    # refused as a duplicate while no visible copy exists.
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: Time.current)
    link.update!(content_sha256: "a" * 64)

    link.soft_delete!

    assert_nil link.reload.content_sha256
  end

  test "a soft-deleted document leaves the archive" do
    link = document_links(:linked_receipt)
    link.entry.update!(reconciled_at: Time.current)
    link.soft_delete!

    assert_not_includes DocumentLink::Search.new(family: link.family, filters: {}).relation.map(&:id), link.id
  end

  test "a soft-deleted document leaves the needs-you strip" do
    family = families(:dylan_family)
    held = DocumentLink.create!(family: family, source: "receipt", status: "queued",
                                original_filename: "held.pdf", failure_message: "no AI provider is configured")
    assert_includes DocumentLink.needs_attention(family), held

    held.soft_delete!

    assert_not_includes DocumentLink.needs_attention(family), held
  end

  test "a soft-deleted document stops counting as ready to review" do
    family = families(:dylan_family)
    link = DocumentLink.create!(family: family, source: "receipt", status: "unlinked", original_filename: "ready.jpg")
    ReceiptImport.create!(family: family, document_link: link, status: :pending,
                          understanding_state: :understood, signage_convention: "inflows_negative")
    before = DocumentLink.pending_review_count_for(family)

    link.soft_delete!

    assert_equal before - 1, DocumentLink.pending_review_count_for(family)
  end

  # The carried-in Task 9 gap: an undo must survive a reprocess. The document
  # records that its auto-post was reversed, so the gate can never silently
  # re-post what the user took back.
  test "a document remembers that its auto-post was undone" do
    link = document_links(:linked_receipt)
    assert_not link.auto_post_undone?

    assert link.mark_auto_post_undone!
    assert link.reload.auto_post_undone?
  end
end
