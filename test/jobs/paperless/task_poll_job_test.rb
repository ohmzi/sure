require "test_helper"

class Paperless::TaskPollJobTest < ActiveJob::TestCase
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("poll-job"))
    @previous_staging = ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"]
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @tmp.to_s
    @link = document_links(:queued_receipt)
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf")
    @link.reload
    @link.mark_processing!
    @link.record_task!("task-9")
    @link.reload
  end

  teardown do
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  def stub_task(status:, document_id: nil, duplicate_of: nil, error_message: nil)
    client = mock("paperless")
    client.stubs(:task).returns(
      Paperless::Task.new(status: status, document_id: document_id, duplicate_of: duplicate_of, error_message: error_message)
    )
    Paperless.stubs(:client).returns(client)
    client
  end

  test "a success finishes the row unlinked and deletes the staged bytes" do
    stub_task(status: :success, document_id: 4242)
    path = @link.staged_path
    Paperless::TaskPollJob.perform_now(@link.id)
    @link.reload
    assert_equal "unlinked", @link.status
    assert_equal 4242, @link.paperless_document_id
    assert_not File.exist?(path)
  end

  test "a duplicate-only success files the duplicate's document id" do
    stub_task(status: :success, duplicate_of: 5555)
    Paperless::TaskPollJob.perform_now(@link.id)
    assert_equal "unlinked", @link.reload.status
    assert_equal 5555, @link.paperless_document_id
  end

  test "a success with neither id fails the row and stops polling" do
    stub_task(status: :success)
    Paperless::TaskPollJob.perform_now(@link.id)
    @link.reload
    assert_equal "failed", @link.status
    assert_nil @link.paperless_task_id
  end

  test "a document id another row already holds fails this row" do
    stub_task(status: :success, document_id: document_links(:linked_receipt).paperless_document_id)
    Paperless::TaskPollJob.perform_now(@link.id)
    assert_equal "failed", @link.reload.status
  end

  test "a task failure marks the row failed, keeping the bytes for retry" do
    client = mock("paperless")
    client.stubs(:task).raises(Paperless::Error.new("bad scan", code: :task_failed))
    Paperless.stubs(:client).returns(client)
    Paperless::TaskPollJob.perform_now(@link.id)
    @link.reload
    assert_equal "failed", @link.status
    assert_equal "bad scan", @link.failure_message
    assert File.exist?(@link.staged_path)
  end

  test "a pending task reschedules with backoff" do
    stub_task(status: :started)
    assert_enqueued_with(job: Paperless::TaskPollJob, args: [ @link.id ]) do
      Paperless::TaskPollJob.perform_now(@link.id)
    end
    assert @link.reload.poll_attempts.positive?
  end

  test "a rejected token holds the row and marks the rotation flag" do
    client = mock("paperless")
    client.stubs(:task).raises(Paperless::Error.new("token", code: :unauthorized))
    Paperless.stubs(:client).returns(client)
    Paperless::TaskPollJob.perform_now(@link.id)
    @link.reload
    assert_equal "queued", @link.status
    assert File.exist?(@link.staged_path)
    assert Setting["paperless_token_invalid_at"].present?
  end

  test "a transport failure or a paperless 5xx reschedules instead of failing" do
    # Ruling M10 (M1), 2026-10-10 close-out: pin the error routing.
    [ :unreachable, :bad_response ].each do |code|
      client = mock("paperless")
      client.stubs(:task).raises(Paperless::Error.new(code.to_s, code: code))
      Paperless.stubs(:client).returns(client)
      assert_enqueued_with(job: Paperless::TaskPollJob, args: [ @link.id ]) do
        Paperless::TaskPollJob.perform_now(@link.id)
      end
      assert_equal "processing", @link.reload.status
    end
  end

  test "an unknown task id reschedules within the attempt budget" do
    # Ruling M10 (M1), 2026-10-10 close-out: :not_found routes like the other
    # transient codes; the attempt budget still bounds it.
    client = mock("paperless")
    client.stubs(:task).raises(Paperless::Error.new("no task", code: :not_found))
    Paperless.stubs(:client).returns(client)
    assert_enqueued_with(job: Paperless::TaskPollJob, args: [ @link.id ]) do
      Paperless::TaskPollJob.perform_now(@link.id)
    end
  end

  test "the backoff waits double from POLL_INTERVAL and cap at MAX_INTERVAL" do
    # Ruling M10 (M1), 2026-10-10 close-out: pin the constants, the doubling
    # curve and the exact attempt boundary (assert_enqueued_with matches `at:`
    # within one second, so the read is exact here).
    assert_equal 3.seconds, Paperless::TaskPollJob::POLL_INTERVAL
    assert_equal 30.seconds, Paperless::TaskPollJob::MAX_INTERVAL
    assert_equal 40, Paperless::TaskPollJob::MAX_ATTEMPTS

    stub_task(status: :pending)
    [ [ 1, 3.seconds ], [ 2, 6.seconds ], [ 3, 12.seconds ], [ 4, 24.seconds ], [ 5, 30.seconds ], [ 39, 30.seconds ] ].each do |attempt, expected|
      @link.note_poll!(attempt - 1) # perform_now bumps the counter to `attempt`
      assert_enqueued_with(job: Paperless::TaskPollJob, args: [ @link.id ], at: expected.from_now) do
        Paperless::TaskPollJob.perform_now(@link.id)
      end
    end

    @link.note_poll!(Paperless::TaskPollJob::MAX_ATTEMPTS - 1) # next attempt = 40: the cap
    assert_no_enqueued_jobs do
      Paperless::TaskPollJob.perform_now(@link.id)
    end
    assert_equal "queued", @link.reload.status
  end

  test "exhausting attempts holds the row retryably instead of looping forever" do
    stub_task(status: :pending)
    @link.note_poll!(Paperless::TaskPollJob::MAX_ATTEMPTS)
    assert_no_enqueued_jobs do
      Paperless::TaskPollJob.perform_now(@link.id)
    end
    @link.reload
    assert_equal "queued", @link.status
    assert_nil @link.paperless_task_id
    assert File.exist?(@link.staged_path)
  end

  test "a retried row polls with a fresh attempt budget" do
    @link.note_poll!(Paperless::TaskPollJob::MAX_ATTEMPTS)
    @link.hold!(message: nil)     # -> queued, task id cleared
    @link.retry_upload!           # -> queued, poll_attempts reset to 0
    @link.mark_processing!
    @link.record_task!("task-9")
    stub_task(status: :pending)
    assert_enqueued_with(job: Paperless::TaskPollJob, args: [ @link.id ]) do
      Paperless::TaskPollJob.perform_now(@link.id)
    end
    assert_equal 1, @link.reload.poll_attempts
  end

  test "a late result never clobbers a row the user already linked" do
    # Simulate a link landing while the poll is in flight: the row is already
    # linked (with a confidence) but still carries a task id, so the poll's
    # guard must refuse to settle it.
    @link.update_columns(status: "linked", entry_id: entries(:transaction).id, confidence: 75)
    stub_task(status: :success, document_id: 4242)
    Paperless::TaskPollJob.perform_now(@link.id)
    @link.reload
    assert_equal "linked", @link.status
    assert_equal 75, @link.confidence
  end
end
