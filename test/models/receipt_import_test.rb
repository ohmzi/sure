require "test_helper"

class ReceiptImportTest < ActiveSupport::TestCase
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
end
