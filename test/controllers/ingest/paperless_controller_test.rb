require "test_helper"

class Ingest::PaperlessControllerTest < ActionDispatch::IntegrationTest
  setup do
    @link = document_links(:queued_receipt)
    # A settled row mid-flight: the guarded transitions under test only act on a
    # processing row, and the ingest payload keys off the paperless document id.
    @link.update_columns(status: "processing", paperless_document_id: 9003)
    @user = User.new(email: Ingest::PaperlessController::INTEGRATION_EMAIL, first_name: "Paperless",
                     last_name: "Ingest", role: "member", family: families(:dylan_family),
                     onboarded_at: Time.current, ui_layout: "intro", password: SecureRandom.hex(16))
    @user.save!
    @key = @user.api_keys.create!(name: "paperless-ingest", scopes: [ "read_write" ], source: "monitoring", key: ApiKey.generate_secure_key)
  end

  def headers(key = @key.plain_key) = { "X-Api-Key" => key }

  test "the configurable path is rejected without a valid key" do
    post ingest_paperless_path, params: { documentId: 9003 }, as: :json
    assert_response :unauthorized
    assert_equal "processing", @link.reload.status
  end

  test "a consumed report moves a processing row to unlinked" do
    post ingest_paperless_path, params: { documentId: 9003, status: "consumed" }, headers: headers, as: :json
    assert_response :ok
    assert_equal "unlinked", @link.reload.status
  end

  test "a failed report settles only a processing row (guarded)" do
    post ingest_paperless_path, params: { documentId: 9003, status: "failed" }, headers: headers, as: :json
    assert_response :ok
    assert_equal "failed", @link.reload.status

    linked = document_links(:linked_receipt)
    post ingest_paperless_path, params: { documentId: linked.paperless_document_id, status: "failed" }, headers: headers, as: :json
    assert_equal "linked", linked.reload.status
  end

  test "an unknown document id is an idempotent no-op" do
    assert_no_difference "DocumentLink.count" do
      post ingest_paperless_path, params: { documentId: 999_999, status: "consumed" }, headers: headers, as: :json
    end
    assert_response :ok
    assert_nil DocumentLink.find_by(paperless_document_id: 999_999)
  end

  test "a malformed body is rejected without touching any row" do
    post ingest_paperless_path, params: { documentId: "not-a-number" }, headers: headers, as: :json
    assert_response :bad_request
    assert_equal "processing", @link.reload.status
  end

  test "the endpoint writes nothing but document_links" do
    assert_no_difference [ "Entry.count", "Account.count" ] do
      post ingest_paperless_path, params: { documentId: 9003, status: "consumed" }, headers: headers, as: :json
    end
  end

  test "a scheme with the wrong scope is rejected" do
    read_key = @user.api_keys.create!(name: "read-only", scopes: [ "read" ], source: "monitoring", key: ApiKey.generate_secure_key)
    post ingest_paperless_path, params: { documentId: 9003, status: "consumed" }, headers: headers(read_key.plain_key), as: :json
    assert_response :forbidden
    assert_equal "processing", @link.reload.status
  end
end
