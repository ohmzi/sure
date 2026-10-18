require "test_helper"

class DocumentProcessingHealthTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "summarizes in-flight, retrying and exhausted reads" do
    DocumentLink.create!(family: @family, source: "statement", status: "queued",
                         original_filename: "retrying.pdf", content_type: "application/pdf",
                         failure_code: "all_readers_failed", failure_message: "temporary",
                         next_attempt_at: 1.hour.from_now)
    DocumentLink.create!(family: @family, source: "statement", status: "processing",
                         original_filename: "flying.pdf", content_type: "application/pdf")
    DocumentLink.create!(family: @family, source: "statement", status: "queued",
                         original_filename: "exhausted.pdf", content_type: "application/pdf",
                         failure_code: "retry_exhausted", failure_message: "stopped")

    health = DocumentProcessingHealth.new(@family)

    assert_equal 3, health.documents
    assert_equal 3, health.in_flight
    assert_equal 1, health.retrying
    assert_equal 1, health.exhausted
    assert_not health.healthy?
  end

  test "separates proven and unverified reads from the latest extraction" do
    receipt = create_link(status: "unlinked", source: "receipt")
    record_extraction(receipt, validations: {})

    proven_statement = create_link(status: "unlinked", source: "statement")
    record_extraction(proven_statement, validations: { "statement_totals_reconcile" => true })

    unverified_statement = create_link(status: "unlinked", source: "statement")
    record_extraction(unverified_statement, validations: { "statement_totals_reconcile" => nil })

    drifted_statement = create_link(status: "pending_review", source: "statement")
    record_extraction(drifted_statement, validations: { "statement_totals_reconcile" => false })

    failed_read = create_link(status: "failed", source: "statement")
    record_extraction(failed_read, status: "failed", validations: {})

    health = DocumentProcessingHealth.new(@family)

    assert_equal 2, health.proven
    assert_equal 2, health.unverified
  end

  test "the latest read decides the outcome, not an earlier attempt" do
    link = create_link(status: "unlinked", source: "statement")
    record_extraction(link, validations: { "statement_totals_reconcile" => false }, created_at: 2.hours.ago)
    record_extraction(link, validations: { "statement_totals_reconcile" => true })

    health = DocumentProcessingHealth.new(@family)

    assert_equal 1, health.proven
    assert_equal 0, health.unverified
  end

  test "separates held reads from retrying and exhausted ones" do
    create_link(status: "queued", source: "statement",
                failure_code: "ocr_unreadable", failure_message: "cannot read")
    create_link(status: "failed", source: "statement", failure_message: "unexpected")
    create_link(status: "queued", source: "statement",
                failure_code: "all_readers_failed", failure_message: "temporary",
                next_attempt_at: 10.minutes.from_now)
    create_link(status: "failed", source: "statement",
                failure_code: "retry_exhausted", failure_message: "stopped")

    health = DocumentProcessingHealth.new(@family)

    assert_equal 2, health.held
    assert_equal 1, health.retrying
    assert_equal 1, health.exhausted
  end

  test "counts documents the matcher routed to a person" do
    create_link(status: "suggested", source: "receipt")
    create_link(status: "pending_review", source: "receipt")
    create_link(status: "unlinked", source: "receipt")

    health = DocumentProcessingHealth.new(@family)

    assert_equal 2, health.awaiting_review
  end

  private
    def create_link(status:, source:, **attributes)
      DocumentLink.create!(family: @family, status: status, source: source,
                           original_filename: "#{status}.pdf", content_type: "application/pdf",
                           **attributes)
    end

    def record_extraction(link, validations:, status: "succeeded", created_at: nil)
      extraction = DocumentExtraction.record!(document_link: link, status: status, validations: validations)
      extraction.update_columns(created_at: created_at) if created_at
      extraction
    end
end
