require "test_helper"

class Paperless::CaptureContentJobTest < ActiveSupport::TestCase
  setup do
    @link = document_links(:unlinked_receipt)
  end

  test "records the paperless document content once, and a tag-less document re-fetches on a later run" do
    # (M8 Task 6) `tag_ids: []` cannot be stored — record_tags! refuses blank
    # names — so the row keeps needing a tag snapshot and the second run
    # fetches the document again. That is the recorded, bounded re-fetch (the
    # backfill task is the refresh path; the content snapshot itself is still
    # written once and never overwritten). tag_names is never called for a
    # document with no tag PKs.
    Paperless::Client.any_instance.expects(:tag_names).never
    Paperless::Client.any_instance.expects(:document).with(9001).twice.returns(
      Paperless::Document.new(id: 9001, title: "Receipt", created: Date.current, tag_ids: [], content: "TOTAL 12.00")
    )

    Paperless::CaptureContentJob.perform_now(@link.id)
    assert_equal "TOTAL 12.00", @link.reload.extracted_text

    Paperless::CaptureContentJob.perform_now(@link.id)
    assert_equal "TOTAL 12.00", @link.reload.extracted_text
    assert_equal [], @link.tags
  end

  test "records the tag snapshot once when the document carries tags" do
    Paperless::Client.any_instance.expects(:document).with(9001).once.returns(
      Paperless::Document.new(id: 9001, title: "Receipt", created: Date.current, tag_ids: [ 1, 3 ], content: "TOTAL 12.00")
    )
    Paperless::Client.any_instance.expects(:tag_names).with([ 1, 3 ]).once.returns({ 1 => "ohmzbudget", 3 => "receipt" })

    Paperless::CaptureContentJob.perform_now(@link.id)

    assert_equal %w[ohmzbudget receipt], @link.reload.tags
    Paperless::CaptureContentJob.perform_now(@link.id) # both snapshots exist: no fetch
  end

  test "a document that already has its content snapshots only the tags" do
    @link.update!(extracted_text: "TOTAL 12.00")
    Paperless::Client.any_instance.expects(:document).with(9001).once.returns(
      Paperless::Document.new(id: 9001, title: "Receipt", created: Date.current, tag_ids: [ 3 ], content: "TOTAL 12.00")
    )
    Paperless::Client.any_instance.expects(:tag_names).with([ 3 ]).once.returns({ 3 => "receipt" })

    Paperless::CaptureContentJob.perform_now(@link.id)
    assert_equal %w[receipt], @link.reload.tags
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
