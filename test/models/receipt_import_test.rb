require "test_helper"

class ReceiptImportTest < ActiveSupport::TestCase
  # assert_enqueued_with lives in ActiveJob::TestHelper (the repo convention —
  # Task 1's recorded deviation: the plan's fences assume the helper is present).
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @link = document_links(:unlinked_receipt)
  end

  test "UNDERSTANDING_STATES is the pinned membership" do
    assert_equal %w[awaiting_ocr understood needs_understanding], ReceiptImport::UNDERSTANDING_STATES
  end

  test "create_from_document_link! builds an awaiting_ocr draft with the receipt signage" do
    draft = ReceiptImport.create_from_document_link!(document_link: @link)

    assert draft.persisted?
    assert_equal "pending", draft.status
    assert_equal "awaiting_ocr", draft.understanding_state
    assert_equal @family.id, draft.family_id
    assert_equal @link.id, draft.document_link_id
    assert_nil draft.account
    assert_equal "inflows_negative", draft.signage_convention
  end

  test "a receipt draft requires a document link and a known understanding state" do
    draft = ReceiptImport.new(family: @family)
    assert_not draft.valid?

    draft.understanding_state = "guessing"
    assert_not draft.valid?
  end

  test "a document link exposes its receipt drafts" do
    assert_includes @link.receipt_imports, imports(:receipt_draft)
  end

  test "capturing content kicks the linked draft" do
    Paperless::Client.any_instance.stubs(:document).returns(
      Paperless::Document.new(id: 9001, title: "Receipt", created: Date.current, tag_ids: [], content: "TOTAL 1.00")
    )

    assert_enqueued_with(job: ReceiptImport::UnderstandJob, args: [ imports(:receipt_draft).id ]) do
      Paperless::CaptureContentJob.perform_now(document_links(:unlinked_receipt).id)
    end
  end
end
