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

  # --- M8 Task 9: quick intake (Ruling M8-L1) --------------------------------

  test "the drop screen is one drop zone and camera, with the override and details" do
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_response :success
    # The one drop zone reuses the archive's dropzone controller (no fork).
    assert_select "[data-controller~='receipt-dropzone']"
    assert_select "[data-action~='drop->receipt-dropzone#drop']"
    # ...with the hidden file input it funnels a dropped file into.
    assert_select "input[type='file'][name='document_file'][data-receipt-dropzone-target='input']"
    # The one-tap source override: auto by default, receipt/bill one tap away.
    assert_select "input[type='radio'][name='source_override'][value=''][checked='checked']"
    assert_select "input[type='radio'][name='source_override'][value='receipt']"
    assert_select "input[type='radio'][name='source_override'][value='bill']"
    # The options live behind Add details: the title field is there...
    assert_select "details summary", text: I18n.t("document_wizards.new.add_details")
    assert_select "input[name='title']"
    # ...and there is NO Continue button (M8 Task 9): choosing the file submits.
    assert_select "input[type='submit']", count: 0
  end

  test "the statement drop screen keeps its single source (no override, no title)" do
    get new_document_wizard_path(source: "statement")
    assert_response :success
    assert_select "input[name='source_override']", count: 0
    assert_select "input[name='title']", count: 0
    assert_select "input[type='submit']", count: 0
  end

  test "the drop screen targets the page when the ladder resolves and the modal when it asks" do
    # (M8 Task 9) The resolved finish is a full-page archive landing, so the
    # form must not stay inside the #modal frame; the ambiguous case still asks
    # at step 3, which renders in the modal as it always has.
    users(:family_admin).update!(default_account: accounts(:depository))
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_select "form[data-turbo-frame='_top']"
    assert_select "form[data-turbo-frame='modal']", count: 0

    sign_in users(:family_member) # two accounts, no default: the ladder cannot resolve
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_select "form[data-turbo-frame='modal']"
    assert_select "form[data-turbo-frame='_top']", count: 0
  end

  test "a resolved account ladder finishes the intake on the archive" do
    users(:family_admin).update!(default_account: accounts(:depository))
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_difference -> { ReceiptImport.count } => 1, -> { DocumentLink.count } => 1 do
      post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }
    end

    draft = ReceiptImport.order(:created_at).last
    assert_redirected_to documents_path # no step-3 GET: the wizard finished
    assert_equal accounts(:depository), draft.account
    assert_match(/reading it in the background/i, flash[:notice])

    follow_redirect!
    assert_response :success
    assert_select "h1", text: I18n.t("documents.index.receipts_bills_title")
    assert_select "span", text: I18n.t("import.accounts.show.title"), count: 0
  end

  test "a single-account user's intake finishes without the step-3 ask" do
    account_shares(:credit_card_shared_with_member).destroy!
    sign_in users(:family_member) # exactly one accessible visible account now
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }

    draft = ReceiptImport.order(:created_at).last
    assert_redirected_to documents_path
    assert_equal accounts(:depository), draft.account
  end

  test "a two-account user without a default still asks at step 3" do
    sign_in users(:family_member)
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }

    draft = ReceiptImport.order(:created_at).last
    assert_redirected_to import_account_path(draft)
    assert_nil draft.account
  end

  test "the one-tap source override wins over the guess and cannot escape receipt or bill" do
    overridden = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    post document_wizard_intake_path(source: "receipt_or_bill"),
         params: { document_file: overridden, source_override: "bill" }
    assert_equal "bill", ReceiptImport.order(:created_at).last.document_link.source

    # A hand-crafted override outside the pair is ignored and the guess (a
    # statement-shaped PDF under this tile) clamps to receipt — the override can
    # never smuggle a statement into the Receipt or Bill tile.
    crafted = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    post document_wizard_intake_path(source: "receipt_or_bill"),
         params: { document_file: crafted, source_override: "statement" }
    assert_equal "receipt", ReceiptImport.order(:created_at).last.document_link.source
  end

  test "the title from Add details rides the intake" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    post document_wizard_intake_path(source: "receipt_or_bill"),
         params: { document_file: file, title: "Laptop purchase" }

    assert_equal "Laptop purchase", DocumentLink.order(:created_at).last.title
  end
end
