require "test_helper"

class StatementOcrJobTest < ActiveJob::TestCase
  setup do
    @import = imports(:pdf)
    @import.update!(account: accounts(:depository), status: :pending)
    @statement = AccountStatement.create_from_upload!(
      family: @import.family,
      account: @import.account,
      file: Rack::Test::UploadedFile.new(
        file_fixture("imports/sample_bank_statement.pdf"),
        "application/pdf",
        true,
        original_filename: "statement.pdf"
      )
    )
    @import.update!(account_statement: @statement)
  end

  # The paperless boundary the test controls: stub the OCR text so the job's
  # spine + template routing is exercised, not pdf-reader.
  def stub_paperless(text: "", configured: true, post: "task-uuid-1", post_error: nil,
                     task: OpenStruct.new(status: :success, document_id: 777, error_message: nil), task_error: nil)
    client = mock
    client.stubs(:configured?).returns(configured)
    if configured
      client.stubs(:tag_id).returns(101) # (Ruling P-m2-1, 2026-10-10 pre-flight)
      post_error ? client.stubs(:post_document).raises(post_error) : client.stubs(:post_document).returns(post)
      task_error ? client.stubs(:task).raises(task_error) : client.stubs(:task).returns(task)
      StatementOcrJob.any_instance.stubs(:ocr_text).returns(text)
    end
    Paperless::Client.stubs(:new).returns(client)
    client
  end

  def link
    DocumentLink.find_by!(account_statement_id: @statement.id, source: "statement")
  end

  test "creates a statement DocumentLink and records the paperless document id" do
    stub_paperless(text: "First National Bank of Nowhere\nnothing to parse")

    StatementOcrJob.perform_now(@import.id)

    assert_equal "statement", link.source
    assert_equal 777, link.paperless_document_id
    assert_equal "unlinked", link.status
  end

  test "an unknown bank lands in needs_template and creates no rows" do
    stub_paperless(text: "First National Bank of Nowhere\nnothing to parse")

    StatementOcrJob.perform_now(@import.id)

    assert @statement.reload.needs_template?
    assert_equal 0, @import.reload.rows.count
    assert @import.pending?
  end

  test "a detected bank generates rows and leaves the import pending" do
    stub_paperless(text: file_fixture("imports/chase_statement.txt").read)

    StatementOcrJob.perform_now(@import.id)

    assert @statement.reload.extracted?
    assert_equal 3, @import.reload.rows.count
    assert @import.pending?
    assert_equal "bank_statement", @import.document_type
  end

  test "a pending paperless task re-enqueues the job" do
    stub_paperless(task: OpenStruct.new(status: :pending, document_id: nil, error_message: nil))

    assert_enqueued_with(job: StatementOcrJob) do
      StatementOcrJob.perform_now(@import.id)
    end
    assert @statement.reload.processing?
  end

  test "a paperless task failure records extraction_failed" do
    stub_paperless(task_error: Paperless::Error.new("OCR failed", code: :task_failed))

    StatementOcrJob.perform_now(@import.id)

    assert @statement.reload.extraction_failed?
    assert_equal 0, @import.reload.rows.count
    assert_equal "failed", link.status
  end

  test "a 401 records extraction_failed and flags the token invalid" do
    stub_paperless(post_error: Paperless::Error.new("unauthorized", code: :unauthorized))

    StatementOcrJob.perform_now(@import.id)

    assert @statement.reload.extraction_failed?
    assert Paperless.token_invalid_at.present?
  end

  test "an unreachable paperless re-schedules then fails after the bound" do
    error = Paperless::Error.new("unreachable", code: :unreachable)
    stub_paperless(post_error: error)

    assert_enqueued_with(job: StatementOcrJob) do
      StatementOcrJob.perform_now(@import.id)
    end
    assert @statement.reload.processing?

    link.note_poll!(5) # at the bound; one more failure settles terminally
    StatementOcrJob.perform_now(@import.id)

    assert @statement.reload.extraction_failed?
  end

  test "a retry after a failed post re-posts instead of reading a nil document" do
    stub_paperless(post_error: Paperless::Error.new("unreachable", code: :unreachable))
    StatementOcrJob.perform_now(@import.id)
    assert link.reload.paperless_task_id.blank?

    stub_paperless(text: file_fixture("imports/chase_statement.txt").read)
    StatementOcrJob.perform_now(@import.id)

    assert_equal 777, link.reload.paperless_document_id
    assert_equal 3, @import.reload.rows.count
  end

  test "an unconfigured paperless client records extraction_failed without raising" do
    stub_paperless(configured: false)

    StatementOcrJob.perform_now(@import.id)

    assert @statement.reload.extraction_failed?
  end
end
