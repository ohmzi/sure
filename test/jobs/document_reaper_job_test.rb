require "test_helper"

class DocumentReaperJobTest < ActiveSupport::TestCase
  # The assert_enqueued_* helpers live in ActiveJob::TestHelper and are not
  # included in ActiveSupport::TestCase automatically in this repo — every job
  # test that asserts on an enqueue includes it explicitly (see
  # test/jobs/document_understanding_job_test.rb and its note). The brief's
  # fence omitted it; without it these tests error with NoMethodError rather
  # than exercising the reaper.
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
  end

  def stranded_link(status:, age:)
    link = DocumentLink.create!(family: @family, source: "other", status: status,
                                original_filename: "r.png", content_type: "image/png")
    link.stage!(io: StringIO.new("BYTES-#{SecureRandom.hex(4)}"), filename: "r.png", content_type: "image/png")
    # The brief's helper wrote `link.update!(status: status, updated_at: age.ago)`
    # directly, but stage! moves the row to `queued` through update_all — which
    # does NOT refresh the in-memory object, so `link.status` was still the
    # created value and the status update was seen as a no-op and never written.
    # A "processing" row therefore stayed "queued", and the fresh-row test
    # asserted a status the row never had. Reloading first makes the intended
    # status actually persist.
    # A real processing row was claimed, so its attempts counter is ≥1. A zero
    # counter means a pre-lease/interrupted claim, which the reaper may take at
    # once — not the shape these tests mean by "processing".
    link.reload.update!(status: status, updated_at: age.ago,
                        attempts_count: status == "processing" ? 1 : 0)
    link
  end

  # A row with real staged bytes, created in `queued` (stage! only writes bytes
  # for a row in queued/processing/failed) so a test can then move it to a
  # settled terminal status and prove the sweep still leaves its bytes alone.
  def with_staged_bytes
    link = DocumentLink.create!(family: @family, source: "other", status: "queued",
                                original_filename: "r.png", content_type: "image/png")
    link.stage!(io: StringIO.new("BYTES-#{SecureRandom.hex(4)}"), filename: "r.png", content_type: "image/png")
    link
  end

  test "it re-enqueues a row whose job died mid-read" do
    stuck = stranded_link(status: "processing", age: 2.hours)

    assert_enqueued_with(job: DocumentUnderstandingJob, args: [ stuck.id ]) do
      DocumentReaperJob.perform_now
    end
  end

  test "it leaves a fresh row alone" do
    fresh = stranded_link(status: "processing", age: 1.minute)

    DocumentReaperJob.perform_now

    assert_equal "processing", fresh.reload.status
    assert_enqueued_jobs 0, only: DocumentUnderstandingJob
  end

  test "it leaves a row with no bytes alone — there is nothing to read" do
    link = DocumentLink.create!(family: @family, source: "other", status: "queued",
                                original_filename: "r.png", content_type: "image/png")
    link.update!(updated_at: 2.hours.ago)

    assert_enqueued_jobs 0, only: DocumentUnderstandingJob do
      DocumentReaperJob.perform_now
    end
  end

  # The other two boundaries the scope's `where(status: %w[queued processing])`
  # draws (guidance 1). A row that already settled — read successfully — or one
  # that failed terminally (DocumentUnderstandingJob's retry-exhausted block)
  # is not mid-read, so the sweep must leave it alone even though it is old and
  # still carries its bytes. Without this guard the sweep would spend a paid
  # provider call on every already-settled document, forever.
  test "it never resurrects a row that was already read successfully" do
    settled = with_staged_bytes
    settled.update!(status: "unlinked", updated_at: 2.hours.ago)

    assert_enqueued_jobs 0, only: DocumentUnderstandingJob do
      DocumentReaperJob.perform_now
    end
  end

  test "it never resurrects a row that failed terminally" do
    failed = with_staged_bytes
    failed.update!(status: "failed", failure_message: "OCR service unreachable after 8 attempts",
                   updated_at: 2.hours.ago)

    assert_enqueued_jobs 0, only: DocumentUnderstandingJob do
      DocumentReaperJob.perform_now
    end
  end

  test "it resumes a read whose owning Sidekiq process is gone and leaves a live one" do
    live = stranded_link(status: "processing", age: 2.hours)
    live.update!(processing_owner: "host:1")
    orphan = stranded_link(status: "processing", age: 2.hours)
    orphan.update!(processing_owner: "host:2")

    Sidekiq::ProcessSet.stubs(:new).returns([ { "hostname" => "host", "pid" => 1 } ])

    assert_enqueued_with(job: DocumentUnderstandingJob, args: [ orphan.id ]) do
      DocumentLink.recover_orphaned_processing!
    end

    assert_equal "queued", orphan.reload.status
    assert_equal "processing", live.reload.status
  end

  test "it reports how many rows it revived" do
    stranded_link(status: "processing", age: 2.hours)
    stranded_link(status: "queued", age: 3.hours)

    assert_equal 2, DocumentReaperJob.perform_now
  end

  # Fix round 1, item 1. The scope keys on a stale `updated_at`, so a read that
  # is genuinely in flight must keep its row fresh — the job touches it as it
  # works (heartbeat). A row that is stale only because its job died has no such
  # touch and is revived; a live read, however long it runs, is not.
  test "an in-flight read is never selected, even after the bound" do
    in_flight = stranded_link(status: "processing", age: 2.hours)
    assert_includes DocumentLink.stranded(before: 30.minutes.ago), in_flight

    # The job's heartbeat makes the row fresh again, exactly as a running read
    # keeps touching it. Now the sweep cannot see it.
    assert in_flight.heartbeat!
    assert_not_includes DocumentLink.stranded(before: 30.minutes.ago), in_flight

    assert_enqueued_jobs 0, only: DocumentUnderstandingJob do
      DocumentReaperJob.perform_now
    end
  end

  # Fix round 1, item 2. `hold!` lands a row in `queued` with a stated reason,
  # and the hold reasons that never self-heal (no OCR, no provider, unreadable)
  # meant the sweep re-enqueued the row every hour forever — re-running OCR on a
  # document the engine cannot read, indefinitely. A failure_message on a queued
  # row is the hold signal, so the sweep skips it.
  test "a row held with a permanent reason is not re-enqueued on the next tick" do
    # Set the message and the stale clock together: a bare update! would bump
    # updated_at to now and the row would fall out of the scope for freshness,
    # not for the hold — passing the test for the wrong reason.
    held = with_staged_bytes
    held.update!(failure_message: "This document could not be read (no_text)",
                 updated_at: 2.hours.ago)

    assert_enqueued_jobs 0, only: DocumentUnderstandingJob do
      DocumentReaperJob.perform_now
    end
  end

  test "a held row becomes sweepable again once reprocessed" do
    held = with_staged_bytes
    held.update!(failure_message: "no OCR service is configured", updated_at: 2.hours.ago)

    held.reprocess!
    held.update!(updated_at: 2.hours.ago)

    assert_enqueued_with(job: DocumentUnderstandingJob, args: [ held.id ]) do
      DocumentReaperJob.perform_now
    end
  end

  # Fix round 2, item 1 (the retry-backoff window). The job parks a row here on a
  # transient OCR failure: queued, with the reason, while retry_on waits. The
  # polynomial's later waits far exceed BOUND, so without the park the sweep
  # would select a waiting row and race the scheduled retry into a second OCR
  # call, a second paid provider call and a second DocumentExtraction. The park
  # carries a message, so the sweep leaves it for the ladder.
  test "a row waiting in retry backoff is never selected" do
    waiting = stranded_link(status: "processing", age: 2.hours)
    assert waiting.await_retry!(message: "OCR service unreachable; a retry is scheduled")
    assert_equal "queued", waiting.reload.status
    # `await_retry!` bumps updated_at through transition!, so by default the row
    # is excluded for FRESHNESS, not for the hold — and the assertion would pass
    # even with the failure_message clause removed (review finding 7). Re-age it
    # so the park is the ONLY thing keeping it out of the sweep.
    waiting.update!(updated_at: 2.hours.ago)

    assert_enqueued_jobs 0, only: DocumentUnderstandingJob do
      DocumentReaperJob.perform_now
    end
  end

  # Closing the backoff hole must not open the crash hole: the retry restarts the
  # read, and mark_processing! clears the backoff message, so a crash after the
  # restart (stale, no code running, no message) is visible to the sweep again.
  test "a read that restarts after being marked is sweepable again if it then crashes" do
    marked = stranded_link(status: "processing", age: 2.hours)
    assert marked.await_retry!(message: "OCR service unreachable; a retry is scheduled")
    # Same masking as the test above (finding 7): re-age so the hold, not
    # freshness, is what excludes the row here.
    marked.update!(updated_at: 2.hours.ago)
    assert_not_includes DocumentLink.stranded(before: 30.minutes.ago), marked

    assert marked.mark_processing!
    marked.update!(updated_at: 2.hours.ago)

    assert_nil marked.reload.failure_message
    assert_includes DocumentLink.stranded(before: 30.minutes.ago), marked
  end
end
