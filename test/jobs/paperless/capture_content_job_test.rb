require "test_helper"

class Paperless::CaptureContentJobTest < ActiveSupport::TestCase
  setup do
    @link = document_links(:unlinked_receipt)
  end

  test "records the paperless document content once and is a no-op afterwards" do
    Paperless::Client.any_instance.expects(:document).with(9001).once.returns(
      Paperless::Document.new(id: 9001, title: "Receipt", created: Date.current, tag_ids: [], content: "TOTAL 12.00")
    )

    Paperless::CaptureContentJob.perform_now(@link.id)
    assert_equal "TOTAL 12.00", @link.reload.extracted_text

    Paperless::CaptureContentJob.perform_now(@link.id) # snapshot exists: no client call
  end

  test "a link without a paperless document id is a silent no-op" do
    Paperless::Client.any_instance.expects(:document).never
    Paperless::CaptureContentJob.perform_now(document_links(:queued_receipt).id)
  end

  test "a 401 notes the token invalid and does not raise" do
    Paperless::Client.any_instance.expects(:document)
      .raises(Paperless::Error.new("unauthorized", code: :unauthorized))

    assert_nothing_raised { Paperless::CaptureContentJob.perform_now(@link.id) }
    assert Paperless.token_invalid_at.present?
  ensure
    Paperless.clear_token_invalid!
  end
end
