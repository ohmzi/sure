require "test_helper"
require_relative "../../support/paperless_test_helper"

class Paperless::UploadJobTest < ActiveJob::TestCase
  include PaperlessTestHelper

  setup do
    @tmp = Pathname.new(Dir.mktmpdir("upload-job"))
    @previous_staging = ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"]
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @tmp.to_s
    @link = document_links(:queued_receipt)
    @link.stage!(io: StringIO.new("%PDF-1.4 x"), filename: "receipt.pdf", content_type: "application/pdf")
    @link.reload
  end

  teardown do
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  def stub_client(post: ->(**) { "task-1" }, task_status: :pending)
    client = mock("paperless")
    client.stubs(:configured?).returns(true)
    client.stubs(:tag_id).returns(1)
    client.stubs(:post_document).returns(post.call)
    Paperless.stubs(:client).returns(client)
    client
  end

  test "posts the staged bytes, records the task id and schedules the poll" do
    stub_client
    assert_enqueued_with(job: Paperless::TaskPollJob, args: [ @link.id ]) do
      Paperless::UploadJob.perform_now(@link.id)
    end
    @link.reload
    assert_equal "processing", @link.status
    assert_equal "task-1", @link.paperless_task_id
    assert File.exist?(@link.staged_path), "bytes must survive until the poll files the row"
  end

  test "resolves paperless tag PKs before posting" do
    client = mock("paperless")
    client.stubs(:configured?).returns(true)
    client.expects(:tag_id).with("ohmzbudget").returns(1)
    client.expects(:tag_id).with("receipt").returns(2)
    client.stubs(:post_document).returns("task-1")
    Paperless.stubs(:client).returns(client)
    Paperless::UploadJob.perform_now(@link.id)
  end

  test "holds the bytes and stays retryable when paperless is unreachable" do
    client = mock("paperless")
    client.stubs(:configured?).returns(true)
    client.stubs(:tag_id).returns(1)
    client.stubs(:post_document).raises(Paperless::Error.new("refused", code: :unreachable))
    Paperless.stubs(:client).returns(client)

    Paperless::UploadJob.perform_now(@link.id)
    @link.reload
    assert_equal "queued", @link.status
    assert_nil @link.paperless_task_id
    assert File.exist?(@link.staged_path)
  end

  test "holds the bytes on a rejected token (no retry loop)" do
    client = mock("paperless")
    client.stubs(:configured?).returns(true)
    client.stubs(:tag_id).returns(1)
    client.stubs(:post_document).raises(Paperless::Error.new("token", code: :unauthorized))
    Paperless.stubs(:client).returns(client)

    Paperless::UploadJob.perform_now(@link.id)
    @link.reload
    assert_equal "queued", @link.status
    assert File.exist?(@link.staged_path)
    assert Setting["paperless_token_invalid_at"].present?
  end

  test "fails with the message when paperless rejects the task, keeping the bytes" do
    client = mock("paperless")
    client.stubs(:configured?).returns(true)
    client.stubs(:tag_id).returns(1)
    client.stubs(:post_document).raises(Paperless::Error.new("no text layer", code: :task_failed))
    Paperless.stubs(:client).returns(client)

    Paperless::UploadJob.perform_now(@link.id)
    @link.reload
    assert_equal "failed", @link.status
    assert_equal "no text layer", @link.failure_message
    assert File.exist?(@link.staged_path)
  end

  test "fails the row when the staged bytes have vanished" do
    stub_client
    File.delete(@link.staged_path)
    Paperless::UploadJob.perform_now(@link.id)
    @link.reload
    assert_equal "failed", @link.status
    assert_match(/staged upload is missing/, @link.failure_message)
  end

  test "is a no-op when paperless is unconfigured" do
    client = mock("paperless")
    client.stubs(:configured?).returns(false)
    Paperless.stubs(:client).returns(client)
    client.expects(:post_document).never
    Paperless::UploadJob.perform_now(@link.id)
    assert_equal "queued", @link.reload.status
  end
end
