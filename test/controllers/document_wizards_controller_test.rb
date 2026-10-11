require "test_helper"

class DocumentWizardsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { sign_in users(:family_admin) }

  test "step 2 renders the camera row above the upload row for both sources" do
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_response :success
    assert_select "input[type='file'][capture='environment'][accept='image/*']"
    assert_select "input[type='file'][name='document_file']"
    # (repaired 2026-10-10, verifier F4) Rails' tag helpers always double-quote
    # attributes — the single-quoted lookups returned nil and raised NoMethodError.
    assert_operator response.body.index('capture="environment"'), :<, response.body.index('name="document_file"')

    # (fix round 1) the statement variant renders too: the description line is
    # per-source, so the name's "both sources" is pinned for real here.
    get new_document_wizard_path(source: "statement")
    assert_response :success
    # The view escapes the copy ("we'll" renders as "we&#39;ll"), so compare the
    # unescaped body against the raw key value.
    assert_includes CGI.unescapeHTML(response.body), I18n.t("document_wizards.new.description_statement")
    assert_select "input[type='file'][name='document_file'][accept='application/pdf,image/*']"
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

  test "the statement tile creates the vault statement and hands off to step 3" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")

    assert_difference -> { AccountStatement.count } => 1, -> { PdfImport.count } => 1 do
      post document_wizard_intake_path(source: "statement"), params: { document_file: file }
    end

    pdf_import = PdfImport.order(:created_at).last
    assert_redirected_to import_account_path(pdf_import)
    assert pdf_import.account_statement.present?
  end

  test "a statement photo is archived and routed to the OCR path" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_enqueued_with(job: StatementOcrJob) do
      post document_wizard_intake_path(source: "statement"), params: { document_file: file }
    end

    statement = AccountStatement.order(:created_at).last
    assert_equal "image/png", statement.content_type
  end

  test "a csv is refused before anything is archived, and the retry is refused too" do
    # (Ruling M7-L6, 2026-10-11 Task 8 fix round 1) A vault-legal CSV is not
    # wizard-legal: before the fix it was archived and the request 500'd on
    # RecordInvalid, identically on every retry.
    file = Rack::Test::UploadedFile.new(file_fixture("imports/transactions.csv"), "text/csv")

    assert_no_difference -> { AccountStatement.count }, -> { PdfImport.count } do
      post document_wizard_intake_path(source: "statement"), params: { document_file: file }
    end

    assert_redirected_to new_document_wizard_path(source: "statement")
    assert_equal I18n.t("document_wizards.create.unsupported_type"), flash[:alert]

    again = Rack::Test::UploadedFile.new(file_fixture("imports/transactions.csv"), "text/csv")
    assert_no_difference -> { AccountStatement.count } do
      post document_wizard_intake_path(source: "statement"), params: { document_file: again }
    end
    assert_equal I18n.t("document_wizards.create.unsupported_type"), flash[:alert]
  end

  test "a failed OCR enqueue alerts instead of flashing the success notice" do
    # (Ruling M7-L6, 2026-10-11 Task 8 fix round 1) The seam reports
    # :ocr_enqueue_failed; the wizard must surface it honestly.
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    StatementOcrJob.stubs(:perform_later).raises(StandardError, "redis down")
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    post document_wizard_intake_path(source: "statement"), params: { document_file: file }

    pdf_import = PdfImport.order(:created_at).last
    assert_redirected_to import_path(pdf_import)
    assert_equal I18n.t("document_wizards.create.statement_ocr_enqueue_failed"), flash[:alert]
    assert_nil flash[:notice]
    assert_equal "extraction_failed", pdf_import.account_statement.reload.extraction_state
  end
end
