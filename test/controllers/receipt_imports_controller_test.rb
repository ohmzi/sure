require "test_helper"

class ReceiptImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @draft = imports(:receipt_understood)
  end

  test "the one-tap override flips receipt and bill" do
    patch receipt_import_path(@draft), params: { receipt_import: { source: "bill" } }

    assert_redirected_to import_path(@draft)
    assert_equal "bill", @draft.document_link.reload.source
  end

  test "an out-of-list source is refused" do
    patch receipt_import_path(@draft), params: { receipt_import: { source: "statement" } }

    assert_equal "receipt", @draft.document_link.reload.source
  end

  test "manual details write the extracted data" do
    draft = imports(:receipt_draft)
    patch receipt_import_path(draft), params: { receipt_import: { total_amount: "9.99", purchase_date: "2026-09-21", payee: "Bodega" } }

    assert draft.reload.understood?
    assert_equal BigDecimal("9.99"), draft.total_amount
  end

  test "a garbage manual total is refused" do
    draft = imports(:receipt_draft)
    patch receipt_import_path(draft), params: { receipt_import: { total_amount: "not money" } }

    assert_redirected_to import_path(draft)
    assert_not draft.reload.understood?
  end

  test "a completed draft is locked" do
    @draft.update!(status: "complete")
    patch receipt_import_path(@draft), params: { receipt_import: { total_amount: "1.00" } }

    assert_response :redirect
    assert_equal BigDecimal("12.00"), @draft.reload.total_amount
  end

  # (D8, Step 5's end-to-end pin) Understanding settles the draft and the review
  # screen renders it — the whole path through the controller writes nothing:
  # only Import#publish (the reviewed publish) ever creates an entry.
  test "understanding a receipt and rendering its review screen writes no money" do
    draft = imports(:receipt_draft)
    draft.document_link.record_content!(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))
    ReceiptImport::UnderstandJob.perform_now(draft.id)
    assert draft.reload.understood?

    assert_no_difference [ -> { Entry.count }, -> { Transaction.count } ] do
      get import_path(draft)
    end
    assert_response :success
  end

  test "a publishable draft renders the publish affordance and the item table" do
    @draft.generate_rows_from_line_items!
    get import_path(@draft)

    assert_response :success
    assert_select "form[action=?]", publish_import_path(@draft)
    assert_select "table"
  end

  test "a needs_understanding draft renders the manual entry form" do
    draft = imports(:receipt_draft)
    draft.document_link.update!(status: "failed", failure_message: "paperless rejected the upload")
    ReceiptImport::UnderstandJob.perform_now(draft.id)
    assert draft.reload.needs_understanding?

    get import_path(draft)

    assert_response :success
    assert_select "input[name='receipt_import[total_amount]']"
    assert_select "input[name='receipt_import[purchase_date]']"
    assert_select "input[name='receipt_import[payee]']"
  end
end
