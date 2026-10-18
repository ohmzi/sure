require "test_helper"
require "tmpdir"
require "fileutils"

class AuditTrailTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @family = @user.family
    @entry = entries(:transaction)
    sign_in @user
  end

  test "a transaction category edit records actor, request id and before/after" do
    assert_difference -> { AuditLog.count }, 1 do
      patch transaction_url(@entry), params: {
        entry: {
          entryable_type: @entry.entryable_type,
          entryable_attributes: {
            id: @entry.entryable_id,
            category_id: categories(:income).id
          }
        }
      }
    end

    log = AuditLog.order(:created_at).last

    assert_equal @family, log.family
    assert_equal @user, log.actor
    assert_equal "transaction.updated", log.action
    assert_equal @entry.transaction, log.auditable
    assert_equal response.headers["X-Request-Id"], log.request_id
    assert_equal categories(:food_and_drink).id, log.before["category_id"]
    assert_equal categories(:income).id, log.after["category_id"]
  end

  test "the transaction drawer renders the activity trail" do
    @entry.transaction.update!(category: categories(:income))

    get transaction_url(@entry), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match I18n.t("audit_logs.activities.transaction.updated"), response.body
    assert_match @user.display_name, response.body
    assert_match "Food &amp; Drink", response.body
    assert_match "Income", response.body
  end

  test "a transaction page never shows another family's audit entries" do
    other_family = families(:empty)
    AuditLog.insert_all([ {
      id: SecureRandom.uuid,
      family_id: other_family.id,
      auditable_type: "Transaction",
      auditable_id: @entry.entryable_id,
      action: "transaction.updated",
      before: { "category_id" => categories(:income).id },
      after: { "category_id" => categories(:food_and_drink).id },
      metadata: { "source" => "web" },
      created_at: Time.current,
      updated_at: Time.current
    } ])

    get transaction_url(@entry), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_no_match I18n.t("audit_logs.activities.transaction.updated"), response.body
  end

  test "a statement review records who reviewed it" do
    statement = create_statement

    assert_difference -> { AuditLog.count }, 1 do
      patch review_account_statement_url(statement)
    end

    log = AuditLog.order(:created_at).last

    assert_equal "account_statement.reviewed", log.action
    assert_equal statement, log.auditable
    assert_equal @family, log.family
    assert_equal @user, log.actor
    assert_equal response.headers["X-Request-Id"], log.request_id
  end

  test "a statement page renders its activity trail" do
    statement = create_statement
    patch review_account_statement_url(statement)

    get account_statement_url(statement)

    assert_response :success
    assert_match I18n.t("audit_logs.activities.account_statement.reviewed"), response.body
    assert_match @user.display_name, response.body
  end

  test "a statement balance edit records before and after" do
    statement = create_statement
    statement.update_columns(opening_balance: 5)

    assert_difference -> { AuditLog.count }, 1 do
      patch account_statement_url(statement), params: {
        account_statement: { opening_balance: "10.00" }
      }
    end

    log = AuditLog.for_auditable(statement).order(:created_at).last

    assert_equal "account_statement.updated", log.action
    assert_equal "5.0", log.before["opening_balance"]
    assert_equal "10.0", log.after["opening_balance"]
    assert_equal @user, log.actor
  end

  test "a statement delete records the statement and its archived document" do
    with_document_store do
      statement = create_statement
      document_link = statement.archive_document_link!(uploader: @user)

      assert_difference -> { AuditLog.count }, 2 do
        delete account_statement_url(statement)
      end

      statement_log = AuditLog.for_auditable(statement).order(:created_at).last
      document_log = AuditLog.for_auditable(document_link).order(:created_at).last

      assert_equal "account_statement.deleted", statement_log.action
      assert_equal statement.id, statement_log.auditable_id
      assert_equal "AccountStatement", statement_log.auditable_type
      assert_equal @family, statement_log.family
      assert_equal statement.filename, statement_log.before["filename"]

      assert_equal "document.deleted", document_log.action
      assert_equal @family, document_log.family
      assert_equal @user, document_log.actor
      assert_equal document_link.reload.original_filename, document_log.metadata["filename"]
      assert_equal statement.id, document_log.before["account_statement_id"]
    end
  end

  test "a failed trail write never turns a successful delete into a 500" do
    with_document_store do
      link = document_links(:unlinked_receipt)
      DocumentLink::Staging.write(io: StringIO.new("receipt bytes"), id: link.id)
      AuditLog.stubs(:create!).raises(ActiveRecord::StatementInvalid.new("audit unavailable"))
      Rails.logger.stubs(:error)

      delete document_url(link)

      assert_response :redirect
      assert link.reload.deleted?
    end
  end

  test "publishing an import records the publish request" do
    import = imports(:transaction)
    TransactionImport.any_instance.stubs(:publish_later)

    assert_difference -> { AuditLog.count }, 1 do
      post publish_import_url(import)
    end

    log = AuditLog.order(:created_at).last

    assert_equal "import.published", log.action
    assert_equal import, log.auditable
    assert_equal @user, log.actor
  end

  test "reverting an import records the revert request" do
    import = imports(:transaction)
    import.update!(status: :complete)
    TransactionImport.any_instance.stubs(:revert_later)

    assert_difference -> { AuditLog.count }, 1 do
      put revert_import_url(import)
    end

    log = AuditLog.order(:created_at).last

    assert_equal "import.reverted", log.action
    assert_equal import, log.auditable
    assert_equal @user, log.actor
  end

  test "deleting a document records the delete without storing its bytes or path" do
    with_document_store do |store|
      link = document_links(:unlinked_receipt)
      DocumentLink::Staging.write(io: StringIO.new("receipt bytes"), id: link.id)

      assert_difference -> { AuditLog.count }, 1 do
        delete document_url(link)
      end

      log = AuditLog.order(:created_at).last

      assert_equal "document.deleted", log.action
      assert_equal link, log.auditable
      assert_equal @user, log.actor
      assert_equal "receipt.png", log.metadata["filename"]
      assert_nil log.metadata["stored_path"]
      assert_no_match(/#{store}/, log.metadata.to_json)
    end
  end

  test "creating a family export records it" do
    assert_difference -> { AuditLog.count }, 1 do
      post family_exports_path
    end

    log = AuditLog.order(:created_at).last

    assert_equal "family_export.created", log.action
    assert_equal "FamilyExport", log.auditable_type
    assert_equal @family, log.family
    assert_equal @user, log.actor
  end

  private
    def create_statement
      AccountStatement.create_from_upload!(
        family: @family,
        account: accounts(:depository),
        file: uploaded_file(
          filename: "audit-#{SecureRandom.hex(4)}.csv",
          content_type: "text/csv",
          content: "date,amount\n2026-01-01,1\n"
        )
      )
    end

    def with_document_store
      Dir.mktmpdir("audit-document-store") do |dir|
        previous = ENV["SURE_DOCUMENT_STORE_DIR"]
        ENV["SURE_DOCUMENT_STORE_DIR"] = dir
        yield dir
      ensure
        ENV["SURE_DOCUMENT_STORE_DIR"] = previous
      end
    end
end
