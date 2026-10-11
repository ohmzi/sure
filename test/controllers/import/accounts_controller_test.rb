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

    assert_redirected_to import_path(@draft)
    assert_equal accounts(:depository), @draft.reload.account
  end

  # (M7 Task 5 deviation, recorded) The finish's destination must actually
  # render the receipt flow: ImportsController#show's non-CSV early return
  # checks `uploaded?`, which was false for a draft whose bytes live on the
  # DocumentLink, so `import_path(draft)` bounced to the CSV upload screen.
  # Task 7's Step 5 and Task 11's journey both read this GET. ReceiptImport now
  # answers `uploaded?` with the staged link (the PdfImport#uploaded? shape).
  test "finishing lands on the receipt flow, not the CSV upload screen" do
    patch import_account_path(@draft), params: { import: { account_id: accounts(:depository).id } }
    follow_redirect!

    assert_response :success
    assert_select "h1", text: I18n.t("imports.receipt_import.pending_title")
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
end
