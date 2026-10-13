require "test_helper"

class AccountStatementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "shows statement vault" do
    get account_statements_url
    assert_response :success
    assert_select "h1", text: I18n.t("account_statements.index.title")
  end

  test "the vault renders in the main chrome, never the settings chrome" do
    get account_statements_path
    assert_response :success
    assert_select "#settings-nav-container", count: 0
    assert_select "div[data-controller~='app-layout']"
    assert_select "h1", text: I18n.t("account_statements.index.title") # still the pinned title key
  end

  test "the statement details page renders in the main chrome, never the settings chrome" do
    # (Ruling M8-C5, 2026-10-11 close-out) the vault's drill-through must not
    # move the user from the main page into the settings chrome.
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "details_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    get account_statement_url(statement)

    assert_response :success
    assert_select "#settings-nav-container", count: 0
    assert_select "div[data-controller~='app-layout']"
    assert_select "h1", text: statement.filename # the page owns its header now
  end

  test "the statements vault leaves the main nav (one Documents entry)" do
    # (Milestone B, design D1) The vault survives for reconciliation — reached
    # from the account tab's "Open inbox" and settings — but it is no longer a
    # sidebar destination, for a member or an admin.
    get documents_path
    assert_select "a[href='#{account_statements_path}']", count: 0

    sign_in users(:family_member)
    get documents_path
    assert_select "a[href='#{account_statements_path}']", count: 0
  end

  test "statement vault only lists linked statements for accessible accounts" do
    accessible_statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "accessible_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    private_account = accounts(:other_asset)
    private_statement = AccountStatement.create_from_upload!(
      family: private_account.family,
      account: private_account,
      file: uploaded_file(filename: "private_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    sign_in users(:family_member)

    get account_statements_url

    assert_response :success
    assert_includes response.body, accessible_statement.filename
    refute_includes response.body, private_statement.filename
    refute_includes response.body, private_account.name
  end

  test "the vault browser renders the statement with its review badge and a viewer link" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "browser_statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 x")
    )

    get account_statements_path

    assert_response :success
    assert_select "tr[id='account_statement_#{statement.id}'], div[id='account_statement_#{statement.id}']" # the row
    assert_select "a[href='#{account_statement_path(statement)}']" # the Details action
    assert_select "a[href='#{viewer_account_statement_path(statement)}']" # the viewer link beside it (Task 4)
    assert_match I18n.t("account_statements.status.linked"), response.body
    # (Milestone B, design D1) The vault is an inbox: its own upload form is
    # gone, so the Documents dropzone is the one way a document enters.
    assert_select "input[type='file'][name='account_statement[files][]']", count: 0
    assert_select "form[action='#{account_statements_path}'][method='post']", count: 0
  end

  test "an unmatched statement keeps its suggestion actions in the browser" do
    suggestion = accounts(:other_asset)
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "suggested.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(suggested_account: suggestion)

    get account_statements_path
    assert_select "form[action='#{link_account_statement_path(statement)}']"
    assert_select "form[action='#{reject_account_statement_path(statement)}']"
  end

  test "non manager cannot open statement vault" do
    sign_in family_guest

    get account_statements_url

    assert_redirected_to accounts_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "non manager cannot view unmatched statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv")
    )
    sign_in family_guest

    get account_statement_url(statement)

    assert_response :not_found
  end

  test "uploads statement to account without importing transactions" do
    assert_difference "AccountStatement.count", 1 do
      assert_no_difference [ "Import.count", "Entry.count", "Transaction.count" ] do
        post account_statements_url, params: {
          account_statement: {
            account_id: @account.id,
            files: [ uploaded_file(filename: "Checking_2024-01.csv", content_type: "text/csv") ]
          }
        }
      end
    end

    statement = AccountStatement.order(:created_at).last
    assert_equal @account, statement.account
    assert statement.linked?
    assert_redirected_to account_url(@account, tab: "statements")
  end

  test "an account-tab upload also creates the DocumentLink the Documents page reads" do
    # Milestone B's gap: the account's statement tab used to create only the
    # vault row, so a statement uploaded here vanished from the unified
    # Documents page. The link (source "statement", the same bytes staged) is
    # what makes DocumentLink the spine every document has.
    store = Pathname.new(Dir.mktmpdir("statement-link"))
    previous = ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"]
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = store.to_s

    assert_difference "DocumentLink.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [ uploaded_file(filename: "tab_statement.csv", content_type: "text/csv") ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    link = statement.archived_document_link
    assert link.present?
    assert_equal "statement", link.source
    assert_equal statement.id, link.account_statement_id
    assert link.stored_path.present?, "the same bytes are staged so the grid can preview it"
  ensure
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = previous
    FileUtils.remove_entry(store) if store&.exist?
  end

  test "member with writable account access can upload linked statement" do
    sign_in users(:family_member)

    assert_difference "AccountStatement.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [ uploaded_file(filename: "member_statement.csv", content_type: "text/csv") ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    assert_equal @account, statement.account
    assert_redirected_to account_url(@account, tab: "statements")
  end

  test "uploads unmatched statement to inbox" do
    assert_difference "AccountStatement.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          files: [ uploaded_file(filename: "Unknown_2024-01.csv", content_type: "text/csv") ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    assert_nil statement.account
    assert statement.unmatched?
    assert_redirected_to account_statement_url(statement)
  end

  test "skips duplicate statement upload" do
    AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [ uploaded_file(filename: "duplicate.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n") ]
        }
      }
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.create.duplicates", count: 1), flash[:alert]
  end

  test "continues upload loop after a validation error" do
    invalid_record = AccountStatement.new
    invalid_record.errors.add(:filename, "is invalid")

    assert_difference "AccountStatement.count", 1 do
      created_statement = AccountStatement.create_from_upload!(
        family: @account.family,
        account: @account,
        file: uploaded_file(filename: "valid-result.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
      )
      upload_sequence = sequence("statement upload processing")
      AccountStatement.expects(:create_from_prepared_upload!).in_sequence(upload_sequence).raises(ActiveRecord::RecordInvalid.new(invalid_record))
      AccountStatement.expects(:create_from_prepared_upload!).in_sequence(upload_sequence).returns(created_statement)

      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [
            uploaded_file(filename: "invalid.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n"),
            uploaded_file(filename: "valid.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
          ]
        }
      }
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.create.success", count: 1), flash[:notice]
    assert_includes flash[:alert], invalid_record.errors.full_messages.to_sentence
  end

  test "rejects invalid statement file type" do
    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          files: [ uploaded_file(filename: "statement.bin", content_type: "application/octet-stream", content: "\x00\x01\x02".b) ]
        }
      }
    end

    assert_redirected_to account_statements_url
    assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
  end

  test "continues upload loop after an invalid file type" do
    assert_difference "AccountStatement.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          files: [
            uploaded_file(filename: "statement.bin", content_type: "application/octet-stream", content: "\x00\x01\x02".b),
            uploaded_file(filename: "valid.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
          ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    assert_redirected_to account_statement_url(statement)
    assert_equal I18n.t("account_statements.create.success", count: 1), flash[:notice]
    assert_includes flash[:alert], I18n.t("account_statements.create.invalid_file_type")
  end

  test "rejects txt and xls statement uploads" do
    [
      uploaded_file(filename: "statement.txt", content_type: "text/plain"),
      uploaded_file(filename: "statement.xls", content_type: "application/vnd.ms-excel")
    ].each do |file|
      assert_no_difference "AccountStatement.count" do
        post account_statements_url, params: {
          account_statement: {
            files: [ file ]
          }
        }
      end

      assert_redirected_to account_statements_url
      assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
    end
  end

  test "rejects empty csv and xlsx statement uploads" do
    [
      uploaded_file(filename: "empty.csv", content_type: "text/csv", content: ""),
      uploaded_file(
        filename: "empty.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        content: ""
      )
    ].each do |file|
      assert_no_difference "AccountStatement.count" do
        post account_statements_url, params: {
          account_statement: {
            files: [ file ]
          }
        }
      end

      assert_redirected_to account_statements_url
      assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
    end
  end

  test "rejects oversized statement upload" do
    original_max_file_size = AccountStatement::MAX_FILE_SIZE
    silence_warnings { AccountStatement.const_set(:MAX_FILE_SIZE, 16) }

    begin
      assert_no_difference "AccountStatement.count" do
        post account_statements_url, params: {
          account_statement: {
            files: [
              uploaded_file(
                filename: "oversized.csv",
                content_type: "text/csv",
                content: "x" * (AccountStatement::MAX_FILE_SIZE + 1)
              )
            ]
          }
        }
      end
    ensure
      silence_warnings { AccountStatement.const_set(:MAX_FILE_SIZE, original_max_file_size) }
    end

    assert_redirected_to account_statements_url
    assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
  end

  test "rejects cross-family account id" do
    other_account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          account_id: other_account.id,
          files: [ uploaded_file(filename: "statement.csv", content_type: "text/csv") ]
        }
      }
    end
    assert_response :not_found
  end

  test "read only shared user cannot upload to account" do
    sign_in users(:family_member)
    account = accounts(:credit_card)

    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          account_id: account.id,
          files: [ uploaded_file(filename: "statement.csv", content_type: "text/csv") ]
        }
      }
    end

    assert_redirected_to account_url(account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "read only shared user sees statement detail without edit controls" do
    account = accounts(:credit_card)
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: account,
      file: uploaded_file(filename: "readonly_statement.csv", content_type: "text/csv")
    )
    sign_in users(:family_member)

    get account_statement_url(statement)

    assert_response :success
    assert_select "input[name='account_statement[period_start_on]']", 0
    assert_select "select[name='account_statement[account_id]']", 0
    assert_select "button", text: I18n.t("account_statements.show.delete"), count: 0
    assert_select "button", text: I18n.t("account_statements.show.save"), count: 0
    assert_select "button", text: I18n.t("account_statements.show.unlink"), count: 0
  end

  test "metadata form does not expose account select for managers" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "manager_statement.csv", content_type: "text/csv")
    )

    get account_statement_url(statement)

    assert_response :success
    assert_select "input[name='account_statement[period_start_on]']", 1
    assert_select "input[name='account_statement[currency]']", 0
    assert_select "select[name='account_statement[currency]'] option[value='USD']"
    assert_select "select[name='account_statement[account_id]']", 0
  end

  test "links suggested statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    patch link_account_statement_url(statement), params: { account_id: @account.id }

    assert_redirected_to account_url(@account, tab: "statements")
    statement.reload
    assert_equal @account, statement.account
    assert statement.linked?
  end

  test "read only shared user cannot relink linked statement to writable account" do
    source_account = accounts(:credit_card)
    target_account = accounts(:depository)
    statement = AccountStatement.create_from_upload!(
      family: source_account.family,
      account: source_account,
      file: uploaded_file(filename: "readonly_relink.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    sign_in users(:family_member)

    patch link_account_statement_url(statement), params: { account_id: target_account.id }

    assert_redirected_to account_url(source_account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_equal source_account, statement.reload.account
  end

  test "link shows friendly error when no target account is available" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch link_account_statement_url(statement)

    assert_redirected_to account_statement_url(statement)
    assert_equal I18n.t("account_statements.link.no_account"), flash[:alert]
    statement.reload
    assert_nil statement.account
    assert statement.unmatched?
  end

  test "unlinks statement back to inbox" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch unlink_account_statement_url(statement)

    assert_redirected_to account_statement_url(statement)
    statement.reload
    assert_nil statement.account
    assert statement.unmatched?
  end

  test "rejects suggestion" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    patch reject_account_statement_url(statement)

    assert_redirected_to account_statements_url
    statement.reload
    assert statement.rejected?
    assert_nil statement.suggested_account
  end

  test "updates metadata" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch account_statement_url(statement), params: {
      account_statement: {
        period_start_on: "2024-01-01",
        period_end_on: "2024-01-31",
        closing_balance: "123.45",
        currency: "usd"
      }
    }

    assert_redirected_to account_statement_url(statement)
    statement.reload
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
    assert_equal 123.45.to_d, statement.closing_balance
    assert_equal "USD", statement.currency
  end

  test "metadata update links selected account" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch account_statement_url(statement), params: {
      account_statement: {
        account_id: @account.id,
        period_start_on: "2024-01-01",
        period_end_on: "2024-01-31"
      }
    }

    assert_redirected_to account_statement_url(statement)
    statement.reload
    assert_equal @account, statement.account
    assert statement.linked?
  end

  test "an unmatched statement page offers a real account picker" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "picker_statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 statement")
    )

    get account_statement_url(statement)

    assert_response :success
    assert_select "form[action='#{link_account_statement_path(statement)}'] select[name='account_id']"
    # The metadata form must still not carry an account select — the picker is
    # its own affordance in the linking panel.
    assert_select "select[name='account_statement[account_id]']", count: 0
  end

  test "the picker assigns through the statement's import, moving both" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "via_import.pdf", content_type: "application/pdf", content: "%PDF-1.4 via import")
    )
    import = PdfImport.find_or_create_from_statement!(statement: statement)
    assert_nil import.account_id

    patch link_account_statement_url(statement), params: { account_id: @account.id }

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal @account, statement.reload.account
    assert_equal @account, import.reload.account,
                 "the import must move with the statement, or publishing its rows is stranded"
  end

  test "the picker links a statement that has no import" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "no_import.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    assert_nil statement.latest_reusable_pdf_import

    patch link_account_statement_url(statement), params: { account_id: @account.id }

    assert_equal @account, statement.reload.account
    assert statement.linked?
  end

  test "assigning from the picker teaches the account its card identity" do
    # The picker must teach the same fill-only identity the /imports/:id confirm
    # does, or the same confirmation seeds last4 via one surface and leaves it
    # blank via this one.
    account = accounts(:credit_card)
    account.update!(last4: nil, account_network: nil)
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "teach_picker.pdf", content_type: "application/pdf", content: "%PDF-1.4 teach")
    )
    link = DocumentLink.create!(family: @account.family, source: "statement", status: "unlinked",
                                account_statement: statement, original_filename: "teach_picker.pdf")
    extraction = DocumentExtraction.record!(document_link: link, status: "succeeded",
                                            verdict: { "card_last4" => "4242", "card_network" => "visa" },
                                            validations: { "last4_in_ocr" => true })
    PdfImport.find_or_create_from_statement!(statement: statement)
             .update!(document_extraction: extraction)

    patch link_account_statement_url(statement), params: { account_id: account.id }

    assert_equal "4242", account.reload.last4
    assert_equal "visa", account.account_network
  end

  test "a refused assignment surfaces an alert instead of a false success" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "locked.pdf", content_type: "application/pdf", content: "%PDF-1.4 locked")
    )
    # A publish in flight makes the import no longer re-targetable under its lock.
    PdfImport.find_or_create_from_statement!(statement: statement).update!(status: :importing)

    patch link_account_statement_url(statement), params: { account_id: @account.id }

    assert_redirected_to account_statement_url(statement)
    assert_equal I18n.t("account_statements.link.account_locked"), flash[:alert]
    assert_nil statement.reload.account
  end

  test "the picker is not rendered once the statement is linked" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "already_linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    get account_statement_url(statement)

    assert_response :success
    assert_select "select[name='account_id']", count: 0
  end

  test "the picker is hidden from a viewer who cannot manage the statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "readonly_picker.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    sign_in users(:intro_user) # a guest, not a statement manager

    # A guest cannot even view an unmatched statement.
    get account_statement_url(statement)

    assert_response :not_found
  end

  test "deletes statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    assert_difference "AccountStatement.count", -1 do
      delete account_statement_url(statement)
    end

    assert_redirected_to account_url(@account, tab: "statements")
  end

  # -- the viewer modal (M8 Task 4) -------------------------------------------

  test "an id outside the family's statements is a 404, never a leak" do
    # (Ruling M8-C4, 2026-10-11 close-out) a REAL foreign-family statement id:
    # this row exists, so without family scoping `set_statement` would find it
    # — the 404 is discriminating, unlike a random UUID alone.
    foreign = AccountStatement.create_from_upload!(
      family: families(:empty), account: nil,
      file: uploaded_file(filename: "foreign_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    get viewer_account_statement_path(foreign)
    assert_response :not_found

    # The random-UUID shape stays as an extra: a stale id dies at the same gate.
    get viewer_account_statement_path(SecureRandom.uuid)
    assert_response :not_found
  end

  test "a csv statement's viewer offers a download instead of a broken preview" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "viewer.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    get viewer_account_statement_path(statement)
    assert_response :success
    assert_select "a[href=?]", rails_blob_path(statement.original_file, disposition: "attachment")
    # (adapted 2026-10-11, Task 4) `assert_text` is a Capybara helper and does not
    # exist in an ActionDispatch::IntegrationTest; this pins the same string.
    assert_match I18n.t("document_browser.viewer.unsupported_title"), response.body
  end

  test "destroy reports failure when statement cannot be deleted" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    AccountStatement.any_instance.stubs(:destroy).returns(false)

    assert_no_difference "AccountStatement.count" do
      delete account_statement_url(statement)
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.destroy.failure"), flash[:alert]
  end

  # -- search (M8 Task 5; the moved M7 Task 10 fence) --------------------------

  test "vault search matches a statement's linked OCR snapshot and the filename fallback" do
    statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family), account: accounts(:depository),
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )
    link = DocumentLink.link_from_upload!(family: statement.family, uploader: users(:family_admin), source: "statement")
    link.update!(account_statement: statement, status: "unlinked")
    link.record_content!("ACME BANK STATEMENT\nTOTAL 1,234.00")

    get account_statements_path(q: { search: "acme bank" })
    assert_match statement.filename, response.body

    get account_statements_path(q: { search: statement.filename })
    assert_match statement.filename, response.body
  end

  # -- the institution facet and the honest amount degradation (M8 Task 7) -----

  test "the statements browser offers the institution facet and explains the missing amount facet" do
    get account_statements_path
    assert_select "input[name='q[merchant]']"
    assert_select "input[name='q[amount_min]']", count: 0
    assert_select "input[name='q[amount_max]']", count: 0
    # (verifier-F4 discipline) fail on the missing key, not on a matching
    # "Translation missing: …" on both sides.
    assert I18n.exists?("document_browser.filters.statements_amount_note")
    assert_match I18n.t("document_browser.filters.statements_amount_note"), response.body
  end

  test "the institution facet narrows the vault list end to end" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "hinted.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(institution_name_hint: "Acme Bank")

    get account_statements_path(q: { merchant: "acme" })
    assert_match statement.filename, response.body
    assert_match "Acme Bank", response.body # the row shows the institution, never an amount

    get account_statements_path(q: { merchant: "nobody" })
    assert_no_match statement.filename, response.body
  end

  test "a malformed scalar q param renders the page instead of a 500" do
    # (Ruling M8-C6, 2026-10-11 close-out) the statements-side mirror of the
    # documents pin: the shape guard keeps the vault a 200 for `?q=coffee`.
    get account_statements_path(q: "coffee")
    assert_response :success

    get account_statements_path(q: [ "coffee" ])
    assert_response :success
  end

  # -- the tag facet on the statements side (Ruling M8-C6) ---------------------

  test "the tag facet narrows the vault through the archived links' stored snapshots" do
    # (Ruling M8-C6, 2026-10-11 close-out) the close-out's named statements tag
    # scope, pinned permanently: the choices come from the stored snapshot on
    # the VISIBLE statements' archived links, and the filter narrows through
    # the same subquery — never a live external call.
    tagged = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "tagged_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    link = DocumentLink.link_from_upload!(family: tagged.family, uploader: users(:family_admin), source: "statement")
    link.update!(account_statement: tagged, status: "unlinked", tags: %w[ohmzbudget statement])
    untagged = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "untagged_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )

    get account_statements_path
    assert_select "input[name='q[tags][]'][value='statement']"  # the choices ride the visible links' snapshots
    assert_select "input[name='q[tags][]'][value='ohmzbudget']"

    get account_statements_path(q: { tags: %w[statement] })
    assert_match tagged.filename, response.body
    assert_no_match untagged.filename, response.body

    # A name no row carries is a real filter: an empty page, never a widened one.
    get account_statements_path(q: { tags: %w[nope] })
    assert_no_match tagged.filename, response.body
  end

  # -- the statements viewer walk (Ruling M8-C6) --------------------------------

  test "a statement row opens the viewer with prev/next over the visible list" do
    # (Ruling M8-C6, 2026-10-11 close-out) the documents-side walk pin's
    # statements mirror: prev/next recompute over the SAME filtered visible
    # relation the index lists.
    older = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "walk_older.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    newer = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "walk_newer.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    older.update_columns(created_at: 2.days.ago)
    newer.update_columns(created_at: 1.day.ago)

    get viewer_account_statement_path(newer)
    assert_select "a[data-viewer-next][href='#{viewer_account_statement_path(older)}']"
    assert_select "a[data-viewer-previous]", count: 0 # newest row: nothing newer

    # The mirror makes the walk discriminating in both directions.
    get viewer_account_statement_path(older)
    assert_select "a[data-viewer-previous][href='#{viewer_account_statement_path(newer)}']"
  end

  # -- the review / extraction facets (M8 Task 9, Ruling M8-L2) ----------------

  test "the review and extraction facets render and narrow the vault list" do
    unmatched = AccountStatement.create_from_upload!(
      family: @account.family, account: nil,
      file: uploaded_file(filename: "facet_unmatched.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    linked = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: uploaded_file(filename: "facet_linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    linked.update_columns(extraction_state: "extraction_failed")

    get account_statements_path
    AccountStatement::Search::REVIEW_FILTERS.each do |review|
      assert_select "input[name='q[review][]'][value='#{review}']"
    end
    AccountStatement::Search::EXTRACTION_FILTERS.each do |extraction|
      assert_select "input[name='q[extraction][]'][value='#{extraction}']"
    end

    get account_statements_path(q: { review: %w[unmatched] })
    assert_match unmatched.filename, response.body
    assert_no_match linked.filename, response.body
    assert_select "input[name='q[review][]'][checked='checked'][value='unmatched']"

    get account_statements_path(q: { extraction: %w[extraction_failed] })
    assert_match linked.filename, response.body
    assert_no_match unmatched.filename, response.body
  end
end
