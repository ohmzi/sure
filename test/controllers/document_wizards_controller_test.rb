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

  test "the intake stages the link, enqueues the native read and lands on the archive" do
    # (Task 8) The wizard no longer creates the draft: the native read job does,
    # once it has a verdict. So the POST stages the link, enqueues exactly the
    # native job (never the paperless upload — one read pipeline only) and lands
    # the user on the archive.
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_no_difference -> { ReceiptImport.count } do
      assert_difference -> { DocumentLink.count } => 1 do
        assert_enqueued_with(job: DocumentUnderstandingJob) do
          post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }
        end
      end
    end

    assert_redirected_to documents_path
    assert_equal I18n.t("document_wizards.create.reading_in_background"), flash[:notice]
    assert_equal "receipt", DocumentLink.order(:created_at).last.source
  end

  test "a statement-shaped filename under the Receipt or Bill tile is still filed receipt or bill" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }

    assert_equal "receipt", DocumentLink.order(:created_at).last.source
    assert_not_equal "statement", DocumentLink.order(:created_at).last.source
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

  test "the statement tile stages the link, enqueues the native read and lands on the archive" do
    # (Task 9) The statement leg is the native read's now: the wizard stages the
    # link and enqueues DocumentUnderstandingJob. The vault row and its PdfImport
    # are created BY that read once it has a verdict and its transactions, so the
    # wizard creates neither — and with no import in hand there is nothing to
    # hand to step 3.
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")

    assert_no_difference -> { AccountStatement.count } => 0, -> { PdfImport.count } => 0 do
      assert_difference -> { DocumentLink.count } => 1 do
        assert_enqueued_with(job: DocumentUnderstandingJob) do
          post document_wizard_intake_path(source: "statement"), params: { document_file: file }
        end
      end
    end

    assert_redirected_to documents_path(source: "statement")
    assert_equal I18n.t("document_wizards.create.statement_processing"), flash[:notice]
    assert_equal "statement", DocumentLink.order(:created_at).last.source
  end

  test "a statement photo is staged and handed to the native read" do
    # An image statement takes the same native read the receipt leg does, so no
    # document is ever read by two pipelines.
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_no_difference -> { AccountStatement.count } => 0 do
      assert_enqueued_with(job: DocumentUnderstandingJob) do
        post document_wizard_intake_path(source: "statement"), params: { document_file: file }
      end
    end

    link = DocumentLink.order(:created_at).last
    assert_equal "statement", link.source
    assert_equal "image/png", link.content_type
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

  test "a failed read enqueue alerts instead of flashing the success notice" do
    # (Ruling M7-L6, kept alive for this leg by Task 9) The intake holds the row
    # back to `queued` when DocumentUnderstandingJob cannot be enqueued. The
    # statement is archived and safe, but the read never started, so the wizard
    # must say so rather than promise a background read that is not happening.
    DocumentUnderstandingJob.stubs(:perform_later).raises(StandardError, "redis down")
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    post document_wizard_intake_path(source: "statement"), params: { document_file: file }

    link = DocumentLink.order(:created_at).last
    assert_redirected_to documents_path(source: "statement")
    assert_equal I18n.t("document_wizards.create.statement_ocr_enqueue_failed"), flash[:alert]
    assert_nil flash[:notice]
    assert_equal "queued", link.status
    assert_includes link.failure_message, "enqueue failed"
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

  test "the drop screen always targets the page — the wizard has no step-3 ask" do
    # (Task 12) Both wizard legs hand the staged link to the native read and
    # land on the archive, so the form escapes the #modal frame in every case.
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_select "form[data-turbo-frame='_top']"
    assert_select "form[data-turbo-frame='modal']", count: 0

    sign_in users(:family_member) # no default account: the target is unchanged
    get new_document_wizard_path(source: "receipt_or_bill")
    assert_select "form[data-turbo-frame='_top']"
    assert_select "form[data-turbo-frame='modal']", count: 0
  end

  test "a resolved account ladder still finishes the receipt intake on the archive" do
    # (Task 8) The ladder no longer runs in the wizard for receipts — the draft
    # does not exist yet, so the path always lands on the archive. The ladder
    # moves into the read pipeline in a later task.
    users(:family_admin).update!(default_account: accounts(:depository))
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_no_difference -> { ReceiptImport.count } do
      assert_difference -> { DocumentLink.count } => 1 do
        post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }
      end
    end

    assert_redirected_to documents_path # no step-3 GET: the wizard finished
    assert_match(/reading it in the background/i, flash[:notice])

    follow_redirect!
    assert_response :success
    assert_select "h1", text: I18n.t("documents.index.receipts_bills_title")
    assert_select "span", text: I18n.t("import.accounts.show.title"), count: 0
  end

  test "a single-account user's receipt intake also finishes without the step-3 ask" do
    account_shares(:credit_card_shared_with_member).destroy!
    sign_in users(:family_member) # exactly one accessible visible account now
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_no_difference -> { ReceiptImport.count } do
      post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }
    end

    assert_redirected_to documents_path
  end

  test "a two-account user without a default no longer asks at step 3 for a receipt" do
    # (Task 8) The step-3 ask was the receipt path's ambiguity route; it is now
    # the statement path's alone until the ladder returns to the pipeline. No
    # draft is created here, so there is nothing to ask about yet.
    sign_in users(:family_member)
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_no_difference -> { ReceiptImport.count } do
      post document_wizard_intake_path(source: "receipt_or_bill"), params: { document_file: file }
    end

    assert_redirected_to documents_path
  end

  test "the one-tap source override wins over the guess and cannot escape receipt or bill" do
    overridden = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    post document_wizard_intake_path(source: "receipt_or_bill"),
         params: { document_file: overridden, source_override: "bill" }
    assert_equal "bill", DocumentLink.order(:created_at).last.source

    # A hand-crafted override outside the pair is ignored and the guess (a
    # statement-shaped PDF under this tile) clamps to receipt — the override can
    # never smuggle a statement into the Receipt or Bill tile.
    crafted = Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    post document_wizard_intake_path(source: "receipt_or_bill"),
         params: { document_file: crafted, source_override: "statement" }
    assert_equal "receipt", DocumentLink.order(:created_at).last.source
  end

  test "the title from Add details rides the intake" do
    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    post document_wizard_intake_path(source: "receipt_or_bill"),
         params: { document_file: file, title: "Laptop purchase" }

    assert_equal "Laptop purchase", DocumentLink.order(:created_at).last.title
  end
end
