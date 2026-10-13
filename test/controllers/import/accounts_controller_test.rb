require "test_helper"

class Import::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @draft = imports(:receipt_draft)
  end

  test "step 3 renders the prefilled account select" do
    users(:family_admin).update!(default_account: accounts(:depository))
    get import_account_path(@draft)

    assert_response :success
    # (repaired 2026-10-10, verifier F1) The fence renders a NATIVE select
    # (imports/_pdf_import.html.erb:53-60 precedent), so this matches real
    # markup and `params.dig(:import, :account_id)` reaches the controller.
    assert_select "select[name='import[account_id]'] option[selected]" do |options|
      assert_equal [ accounts(:depository).id ], options.map { |o| o["value"] }
    end
  end

  test "finishing writes the account and leaves the modal" do
    patch import_account_path(@draft), params: { import: { account_id: accounts(:depository).id } }

    # (Owner decision 2026-10-11, hotfix; the intake hotfix's shape, re-applied
    # by M8 Task 9) fire-and-forget: the finish lands on the archive (with a
    # "reading in the background" notice), where the document appears immediately
    # with its live status, never on the blocking "Reading your document" screen.
    assert_redirected_to documents_path
    assert_match(/reading it in the background/i, flash[:notice])
    assert_equal accounts(:depository), @draft.reload.account
  end

  # (M7 Task 5 deviation, recorded; superseded by the hotfix's shape) The finish
  # no longer lands on the receipt flow's blocking "Reading your document"
  # screen: it lands on the ARCHIVE, where the draft's row carries the live
  # status. ImportsController#show's non-CSV early return still checks
  # `uploaded?`, and ReceiptImport answers it with the staged link (the
  # PdfImport#uploaded? shape) — the review screen is reached from the row.
  test "finishing lands on the archive, not the reading screen" do
    patch import_account_path(@draft), params: { import: { account_id: accounts(:depository).id } }
    follow_redirect!

    assert_response :success
    assert_select "h1", text: I18n.t("documents.index.title")
    assert_select "h1", text: I18n.t("imports.receipt_import.pending_title"), count: 0
  end

  test "an account the user cannot reach is refused" do
    sign_in users(:family_member) # accessible: the shared depository + credit card only

    patch import_account_path(@draft), params: { import: { account_id: accounts(:investment).id } }

    assert_response :redirect
    assert_nil @draft.reload.account
  end

  test "a guest cannot confirm" do
    guest = users(:family_admin)
    guest.update!(role: "guest")
    sign_in guest
    get import_account_path(@draft)
    assert_response :redirect
  end

  # --- (Ruling M7-L7, 2026-10-11 close-out) the statement-backed move ---------
  #
  # set_import is family-scoped, so any member could PATCH this route for any
  # family statement-backed import. The move re-targets the STATEMENT
  # (PdfImport#assign_account! -> link_to_account!) and unwinds the
  # reconciliations it holds on the account being left, so the statement's
  # CURRENT-account permission is required before the move - the
  # ImportsController#require_statement_import_permission! /
  # AccountStatement#manageable_by? mirror. The member here holds the
  # statement's account (credit_card) read_only but CAN write the target
  # (depository, full_control), so the old target-only check let the move run.

  test "a member without manage rights on the statement's current account cannot move it" do
    import, statement = statement_backed_import(account: accounts(:credit_card))
    sign_in users(:family_member)

    patch import_account_path(import), params: { import: { account_id: accounts(:depository).id } }

    assert_response :redirect
    assert_nil flash[:notice]
    assert_equal accounts(:credit_card), import.reload.account
    assert_equal accounts(:credit_card), statement.reload.account
  end

  test "a member with manage rights on the statement's current account can move it" do
    import, statement = statement_backed_import(account: accounts(:depository))
    # The member can write depository but not credit_card (read_only), so a
    # genuine move needs both ends writable - upgrade the share.
    account_shares(:credit_card_shared_with_member).update!(permission: "full_control")
    sign_in users(:family_member)

    patch import_account_path(import), params: { import: { account_id: accounts(:credit_card).id } }

    # A statement-backed finish lands on the statements-filtered archive (the
    # hotfix's shape, re-applied by M8 Task 9).
    assert_redirected_to documents_path(source: "statement")
    assert_equal accounts(:credit_card), import.reload.account
    assert_equal accounts(:credit_card), statement.reload.account
  end

  test "the owner path still moves a statement-backed import" do
    import, statement = statement_backed_import(account: accounts(:investment))

    patch import_account_path(import), params: { import: { account_id: accounts(:depository).id } }

    assert_redirected_to documents_path(source: "statement")
    assert_equal accounts(:depository), import.reload.account
    assert_equal accounts(:depository), statement.reload.account
  end

  # --- Task 11: the confirmed match teaches the account its identity ----------
  #
  # Spec N14's learned half. The brief placed these in the job test, but they
  # drive `patch import_account_path` — the real controller — and
  # `ActiveSupport::TestCase` has no HTTP verbs or `sign_in`. They live here so
  # the assertion is about the app's behaviour, not a test seam.

  test "confirming the read teaches the account its own card identity" do
    account = accounts(:credit_card)
    account.update!(last4: nil, account_network: nil)
    draft = read_receipt

    # The user confirms on the step-3 screen, driven through the real controller.
    patch import_account_path(draft), params: { import: { account_id: account.id } }

    assert_equal "4242", account.reload.last4
    assert_equal "visa", account.account_network
  end

  test "a learned last4 never overwrites one the user typed" do
    account = accounts(:credit_card)
    account.update!(last4: "9999", account_network: "amex")
    draft = read_receipt

    patch import_account_path(draft), params: { import: { account_id: account.id } }

    assert_equal "9999", account.reload.last4, "a model's reading must never overwrite the user's value"
    assert_equal "amex", account.account_network
  end

  private
    # A receipt read by the real pipeline, so the confirm below acts on the
    # DocumentExtraction the job actually recorded rather than a hand-built seam.
    def read_receipt
      link = DocumentLink.create!(family: families(:dylan_family), created_by: users(:family_admin),
                                  source: "other", status: "queued", original_filename: "receipt.png",
                                  content_type: "image/png")
      link.stage!(io: StringIO.new("PNG-#{SecureRandom.hex(4)}"), filename: "receipt.png",
                  content_type: "image/png")
      link.update!(status: "queued")
      stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
      Provider::Registry.stubs(:preferred_llm_provider).returns(
        OcrTestHelper::StubDocumentProvider.new(
          "document_class" => "receipt", "total" => "12.34", "date" => "2026-10-01",
          "payee" => "Acme Store", "currency" => "USD",
          "card_last4" => "4242", "card_network" => "visa",
          "line_items" => [ { "description" => "Coffee", "amount" => "12.34" } ]
        )
      )
      DocumentUnderstandingJob.perform_now(link.id)
      ReceiptImport.find_by!(document_link_id: link.id)
    end

    # A statement-backed PdfImport, the seed shape M2's controller tests use.
    def statement_backed_import(account:)
      import = imports(:pdf)
      import.update!(account: account)
      statement = AccountStatement.create_from_upload!(
        family: import.family,
        account: account,
        file: Rack::Test::UploadedFile.new(
          file_fixture("imports/sample_bank_statement.pdf"),
          "application/pdf", true, original_filename: "statement.pdf"
        )
      )
      import.update!(account_statement: statement)
      [ import, statement ]
    end
end
