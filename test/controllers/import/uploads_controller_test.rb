require "test_helper"

class Import::UploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:transaction)
  end

  test "show" do
    get import_upload_url(@import)
    assert_response :success
  end

  test "uploads valid csv by copy and pasting" do
    patch import_upload_url(@import), params: {
      import: {
        raw_file_str: file_fixture("imports/valid.csv").read,
        col_sep: ","
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)
    assert_equal "CSV uploaded successfully.", flash[:notice]
  end

  test "uploads valid csv by file" do
    patch import_upload_url(@import), params: {
      import: {
        import_file: file_fixture_upload("imports/valid.csv"),
        col_sep: ","
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)
    assert_equal "CSV uploaded successfully.", flash[:notice]
  end

  test "account select does not leak unshared family accounts (#1803)" do
    sign_in users(:family_member)

    get import_upload_url(@import)

    assert_response :success
    assert_select 'select[name="import[account_id]"] option', text: "Checking Account"
    assert_select 'select[name="import[account_id]"] option', text: "Collectable Account", count: 0
    assert_select 'select[name="import[account_id]"] option', text: "IOU (personal debt to friend)", count: 0
    assert_select 'select[name="import[account_id]"] option', text: "Plaid Depository Account", count: 0
  end

  test "respects SURE_IMPORT_MAX_NDJSON_SIZE_MB when uploading Sure import file (#3010)" do
    configured_limit = 2.megabytes
    SureImport.stubs(:max_ndjson_size).returns(configured_limit)

    sure_import = imports(:sure)
    oversized_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (configured_limit + 1)),
      "application/x-ndjson",
      original_filename: "all.ndjson"
    )

    patch import_upload_url(sure_import), params: {
      import: { ndjson_file: oversized_file }
    }

    assert_response :unprocessable_entity
    assert_equal I18n.t("imports.create.file_too_large", max_size: configured_limit / 1.megabyte), flash[:alert]
  end

  test "invalid csv cannot be uploaded" do
    patch import_upload_url(@import), params: {
      import: {
        import_file: file_fixture_upload("imports/invalid.csv"),
        col_sep: ","
      }
    }

    assert_response :unprocessable_entity
    assert_equal "Must be valid CSV with headers and at least one row of data", flash[:alert]
  end

  test "uploads a valid OFX file, archives it, and generates rows" do
    import = OfxImport.create!(family: users(:family_admin).family, account: accounts(:depository))

    patch import_upload_url(import), params: {
      import: {
        import_file: file_fixture_upload("imports/sample.ofx", "application/x-ofx"),
        account_id: accounts(:depository).id
      }
    }

    assert_redirected_to import_clean_url(import)
    import.reload
    assert_equal 3, import.rows.count
    assert import.account_statement.present?
    assert import.account_statement.ofx?
    assert_equal "application/x-ofx", import.account_statement.content_type
  end

  test "rejects a malformed OFX file" do
    import = OfxImport.create!(family: users(:family_admin).family, account: accounts(:depository))

    assert_no_difference [ "AccountStatement.count", "Import::Row.count" ] do
      patch import_upload_url(import), params: {
        import: {
          import_file: file_fixture_upload("imports/valid.csv", "text/csv"),
          account_id: accounts(:depository).id
        }
      }
    end

    assert_response :unprocessable_entity
    assert_nil import.reload.account_statement
  end

  test "requires an account for an OFX import" do
    import = OfxImport.create!(family: users(:family_admin).family)

    patch import_upload_url(import), params: {
      import: { import_file: file_fixture_upload("imports/sample.ofx", "application/x-ofx") }
    }

    assert_response :unprocessable_entity
    assert_equal 0, import.reload.rows.count
  end

  test "uploading the same OFX file twice reuses one archived statement and warns" do
    first = OfxImport.create!(family: users(:family_admin).family, account: accounts(:depository))
    patch import_upload_url(first), params: {
      import: { import_file: file_fixture_upload("imports/sample.ofx", "application/x-ofx"), account_id: accounts(:depository).id }
    }

    second = OfxImport.create!(family: users(:family_admin).family, account: accounts(:depository))
    patch import_upload_url(second), params: {
      import: { import_file: file_fixture_upload("imports/sample.ofx", "application/x-ofx"), account_id: accounts(:depository).id }
    }

    assert_equal 1, AccountStatement.where(content_type: "application/x-ofx").count
    assert_equal first.reload.account_statement, second.reload.account_statement
    assert_equal "That OFX file is already archived — reusing the stored statement and re-importing its rows.", flash[:notice]
    assert_equal 3, second.rows.count
  end

  test "rejects an OFX upload the vault will not accept" do
    import = OfxImport.create!(family: users(:family_admin).family, account: accounts(:depository))
    disallowed = Rack::Test::UploadedFile.new(
      file_fixture("imports/sample.ofx"), "application/x-ofx", true, original_filename: "statement.ofx.bak"
    )

    assert_no_difference [ "AccountStatement.count", "Import::Row.count" ] do
      patch import_upload_url(import), params: {
        import: { import_file: disallowed, account_id: accounts(:depository).id }
      }
    end

    assert_response :unprocessable_entity
    assert_equal "Must be a valid OFX/QFX file", flash[:alert]
  end

  test "the OFX upload screen renders the OFX form" do
    import = OfxImport.create!(family: users(:family_admin).family)

    get import_upload_url(import)

    assert_response :success
    assert_select "input#import_import_file_ofx[accept='.ofx,.qfx']", count: 1
    assert_select "select[name='import[account_id]']", count: 1
  end
end
