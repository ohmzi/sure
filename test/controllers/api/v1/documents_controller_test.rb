# frozen_string_literal: true

require "test_helper"

class Api::V1::DocumentsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Document upload",
      key: ApiKey.generate_secure_key,
      scopes: [ "read_write" ],
      source: "mobile"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Document upload read only",
      key: ApiKey.generate_secure_key,
      scopes: [ "read" ],
      source: "web"
    )

    clear_rate_limits
  end

  teardown { clear_rate_limits }

  test "uploads an image into the current user's family and returns the document" do
    document = nil

    assert_difference "DocumentLink.count", 1 do
      assert_enqueued_with(job: DocumentUnderstandingJob) do
        post api_v1_documents_url,
             params: { file: receipt_upload, currency: "usd" },
             headers: api_headers(@api_key)
      end
    end

    assert_response :accepted
    assert_equal "application/json", response.media_type

    body = response.parsed_body
    document = DocumentLink.find(body.dig("document", "id"))
    assert_equal "processing", body.dig("document", "status")
    assert_equal "processing", document.status
    assert_equal @family, document.family
    assert_equal @user, document.created_by
    assert_equal "receipt.png", document.original_filename
    assert_equal "USD", document.currency
    assert document.stored_path.present?
    refute_includes response.body, "turbo-stream"
  ensure
    DocumentLink::Staging.delete(document&.stored_path)
  end

  test "accepts a PDF by its signature like the web intake" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("%PDF-1.4\n%%EOF\n"), "application/octet-stream", original_filename: "statement.pdf"
    )
    document = nil

    assert_difference "DocumentLink.count", 1 do
      post api_v1_documents_url, params: { file: upload }, headers: api_headers(@api_key)
    end

    assert_response :accepted
    document = created_document
    assert_equal "statement.pdf", document.original_filename
  ensure
    DocumentLink::Staging.delete(document&.stored_path)
  end

  test "rejects a file the web intake cannot classify" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("\x00\x01binary"), "application/octet-stream", original_filename: "thing.bin"
    )

    assert_no_difference [ "DocumentLink.count", "Import.count" ] do
      post api_v1_documents_url, params: { file: upload }, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_file_type", response.parsed_body["error"]
    assert_equal I18n.t("document_intake.rejected"), response.parsed_body["message"]
  end

  test "refuses a bank export instead of creating an import behind the caller's back" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("Date,Description,Amount\n2026-10-01,Cafe,-4.50\n"), "text/csv", original_filename: "bank.csv"
    )

    assert_no_difference [ "DocumentLink.count", "Import.count" ] do
      post api_v1_documents_url, params: { file: upload }, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_file_type", response.parsed_body["error"]
    assert_equal I18n.t("document_intake.documents_only"), response.parsed_body["message"]
  end

  test "rejects a file over the web intake size cap with 413" do
    oversized = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (DocumentLink::Staging::MAX_BYTES + 1)),
      "image/png",
      original_filename: "huge.png"
    )

    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, params: { file: oversized }, headers: api_headers(@api_key)
    end

    assert_response :content_too_large
    assert_equal "file_too_large", response.parsed_body["error"]
  end

  test "rejects a missing file" do
    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "missing_file", response.parsed_body["error"]
  end

  test "rejects a file param that is not an upload" do
    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, params: { file: "not-an-upload" }, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "missing_file", response.parsed_body["error"]
  end

  test "refuses bytes the family already archived" do
    post api_v1_documents_url, params: { file: receipt_upload }, headers: api_headers(@api_key)
    assert_response :accepted
    first = created_document

    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, params: { file: receipt_upload }, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "duplicate_document", response.parsed_body["error"]
  ensure
    DocumentLink::Staging.delete(first&.stored_path)
  end

  test "requires authentication" do
    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, params: { file: receipt_upload }
    end

    assert_response :unauthorized
  end

  test "requires a write scope" do
    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, params: { file: receipt_upload }, headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body["error"]
  end

  test "guests cannot upload" do
    guest = users(:intro_user)
    guest.api_keys.active.destroy_all
    key = ApiKey.create!(
      user: guest,
      name: "Guest document upload",
      key: ApiKey.generate_secure_key,
      scopes: [ "read_write" ],
      source: "mobile"
    )
    Redis.new.del("api_rate_limit:#{key.id}")

    assert_no_difference "DocumentLink.count" do
      post api_v1_documents_url, params: { file: receipt_upload }, headers: api_headers(key)
    end

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
  end

  test "scopes the upload to the authenticated family and ignores a supplied family_id" do
    other_user = users(:empty)
    other_user.api_keys.active.destroy_all
    other_key = ApiKey.create!(
      user: other_user,
      name: "Other family document upload",
      key: ApiKey.generate_secure_key,
      scopes: [ "read_write" ],
      source: "mobile"
    )
    Redis.new.del("api_rate_limit:#{other_key.id}")

    document = nil
    assert_difference "DocumentLink.count", 1 do
      post api_v1_documents_url,
           params: { file: receipt_upload, family_id: @family.id },
           headers: api_headers(other_key)
    end

    assert_response :accepted
    document = created_document
    assert_equal other_user.family, document.family
    refute_equal @family, document.family
  ensure
    DocumentLink::Staging.delete(document&.stored_path)
    Redis.new.del("api_rate_limit:#{other_key&.id}")
  end

  private
    def receipt_upload
      Rack::Test::UploadedFile.new(
        file_fixture("receipts/receipt.png"),
        "image/png",
        original_filename: "receipt.png"
      )
    end

    def created_document
      DocumentLink.find(response.parsed_body.dig("document", "id"))
    end

    def clear_rate_limits
      [ @api_key, @read_only_api_key ].compact.each do |key|
        Redis.new.del("api_rate_limit:#{key.id}")
      end
    end
end
