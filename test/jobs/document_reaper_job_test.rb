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
    link.reload.update!(status: status, updated_at: age.ago)
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

  test "it reports how many rows it revived" do
    stranded_link(status: "processing", age: 2.hours)
    stranded_link(status: "queued", age: 3.hours)

    assert_equal 2, DocumentReaperJob.perform_now
  end
end
