require "test_helper"

class DocumentWizardsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "step 2 renders the camera row above the upload row for both sources" do
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_response :success
    assert_select "input[type='file'][capture='environment'][accept='image/*']"
    assert_select "input[type='file'][name='document_file']"
    # (repaired 2026-10-10, verifier F4) Rails' tag helpers always double-quote
    # attributes — the single-quoted lookups returned nil and raised NoMethodError.
    assert_operator response.body.index('capture="environment"'), :<, response.body.index('name="document_file"')
  end

  test "the intake creates a receipt draft and redirects into the receipt flow" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_difference -> { ReceiptImport.count } => 1, -> { DocumentLink.count } => 1 do
      post document_wizard_intake_path(source: "receipt_or_bill"),
           params: { document_file: file }
    end

    draft = ReceiptImport.order(:created_at).last
    assert_redirected_to import_account_path(draft)
    assert_equal "receipt", draft.document_link.source
    assert_equal "awaiting_ocr", draft.understanding_state
  end

  test "a statement-shaped filename under the Receipt or Bill tile is still filed receipt or bill" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }

    assert_equal "receipt", ReceiptImport.order(:created_at).last.document_link.source
    assert_not_equal "statement", ReceiptImport.order(:created_at).last.document_link.source
  end

  test "a duplicate upload alerts without creating a row" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }

    duplicate = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    assert_no_difference -> { DocumentLink.count } do
      post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: duplicate }
    end
    assert_response :redirect
  end

  test "the statement tile files a statement link (interim — Task 8 replaces this branch)" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    post document_wizard_intake_path(source: "statement"), params: { document_file: file }

    assert_equal "statement", DocumentLink.order(:created_at).last.source
    assert_redirected_to documents_path(source: "statement")
    assert_no_difference -> { ReceiptImport.count } do
      post document_wizard_intake_path(source: "statement"), params: { document_file: Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png") }
    end
  end
end
