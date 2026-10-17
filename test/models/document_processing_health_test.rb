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
end
