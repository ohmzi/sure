require "test_helper"

class DocumentLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("doc-links"))
    @previous_staging = ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"]
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @tmp.to_s
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @link = document_links(:linked_receipt)
  end

  teardown do
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  test "create rejects an unknown source" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "png")
    assert_no_difference "DocumentLink.count" do
      post documents_path, params: { document: file, source: "bogus" }
    end
    assert_response :unprocessable_entity
  end

  test "create stages the bytes and enqueues the upload job" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "png-bytes")
    assert_difference "DocumentLink.count", 1 do
      assert_enqueued_with(job: Paperless::UploadJob) do
        post documents_path, params: { document: file, source: "receipt", title: "New" }
      end
    end
    link = DocumentLink.order(:created_at).last
    assert_equal "processing", link.status
    assert link.staged_path.present?
  ensure
    DocumentLink::Staging.delete(link&.staged_path)
  end

  test "file streams the proxied bytes with the range response" do
    Paperless::Client.any_instance.stubs(:file).yields(
      "%PDF", OpenStruct.new(status: 206, response_headers: { "content-type" => "application/pdf", "content-range" => "bytes 0-3/8", "accept-ranges" => "bytes" })
    )
    get file_document_path(@link, kind: "preview"), headers: { "Range" => "bytes=0-3" }
    assert_response 206
    assert_equal "application/pdf", response.headers["Content-Type"]
    assert_equal "bytes 0-3/8", response.headers["Content-Range"]
    assert_equal "%PDF", response.body
  end

  test "file refuses a kind paperless does not serve" do
    get file_document_path(@link, kind: "weird")
    assert_response :bad_request
  end

  test "file refuses a document with no paperless copy" do
    processing = document_links(:held_bill)
    processing.update_columns(status: "processing", paperless_document_id: nil)
    get file_document_path(processing, kind: "preview")
    assert_response :not_found
  end

  test "file maps a paperless 401 to a rotation warning" do
    Paperless::Client.any_instance.stubs(:file).raises(Paperless::Error.new("token", code: :unauthorized))
    get file_document_path(@link, kind: "preview")
    assert_response :bad_gateway
    assert Setting["paperless_token_invalid_at"].present?
  ensure
    Setting["paperless_token_invalid_at"] = nil
  end

  test "link refuses a document with no paperless copy" do
    processing = document_links(:held_bill)
    processing.update_columns(status: "processing", paperless_document_id: nil)
    post link_document_path(processing), params: { entry_id: entries(:transaction).id }
    assert_response :conflict
    assert_equal "processing", processing.reload.status
  end

  test "link links an unlinked document to an entry" do
    post link_document_path(@link, params: { entry_id: entries(:transaction).id })
    assert_response :redirect
    assert_equal "linked", @link.reload.status
  end

  test "unlink clears the entry and confidence" do
    post unlink_document_path(@link)
    assert_response :redirect
    @link.reload
    assert_equal "unlinked", @link.status
    assert_nil @link.confidence
  end

  test "retry re-enqueues only a row with held bytes" do
    @link.update_columns(status: "failed", paperless_task_id: nil)
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf") # -> queued with staged_path
    assert_enqueued_with(job: Paperless::UploadJob) do
      post retry_document_path(@link)
    end
    assert_response :redirect
    assert_equal "queued", @link.reload.status
  end

  test "retry refuses a row with no held upload" do
    @link.update_columns(status: "failed", staged_path: nil)
    post retry_document_path(@link)
    assert_response :conflict
  end

  test "destroy removes the row and its staged bytes" do
    DocumentLink::Staging.write(io: StringIO.new("x"), id: @link.id)
    @link.update_columns(staged_path: DocumentLink::Staging.root.join(@link.id).to_s)
    path = @link.reload.staged_path
    assert_difference "DocumentLink.count", -1 do
      delete document_path(@link)
    end
    assert_not File.exist?(path)
  end
end
