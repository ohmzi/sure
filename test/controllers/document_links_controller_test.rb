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

  test "create holds the row back to queued with its bytes when the enqueue raises" do
    # Ruling 11 (M1), 2026-10-10 close-out: without this fence a raise between
    # stage! and enqueue strands the row in `processing` — no poll is ever
    # scheduled (the job schedules it), the retry route refuses `processing`,
    # and the (family, sha256) unique index blocks re-uploading the same bytes.
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "png-bytes")
    Paperless::UploadJob.stubs(:perform_later).raises(StandardError, "redis down")
    assert_difference "DocumentLink.count", 1 do
      post documents_path, params: { document: file, source: "receipt" }
    end
    assert_response :redirect
    link = DocumentLink.order(:created_at).last
    assert_equal "queued", link.status
    assert link.staged_path.present?
    assert File.exist?(link.staged_path), "the held row keeps its staged bytes for the retry route"
    assert_equal I18n.t("documents.create.held"), flash[:alert]
  ensure
    DocumentLink::Staging.delete(link&.staged_path)
  end

  test "create refuses a non-file document, an over-long title and an over-long content type without writing" do
    # Ruling M6 (M1), 2026-10-10 close-out: one test, three refusals — each runs
    # before any row or bytes are written.
    assert_no_difference "DocumentLink.count" do
      assert_no_difference -> { Dir.children(@tmp).size } do
        post documents_path, params: { document: "not-a-file", source: "receipt" }
        assert_response :bad_request

        post documents_path, params: { document: uploaded_file(filename: "r.png", content_type: "image/png", content: "x"),
                                       source: "receipt", title: "t" * (DocumentLinksController::MAX_TITLE_LENGTH + 1) }
        assert_response :unprocessable_entity

        post documents_path, params: { document: uploaded_file(filename: "r.png", content_type: "image/#{"x" * (DocumentLinksController::MAX_CONTENT_TYPE_LENGTH + 1)}", content: "y"),
                                       source: "receipt" }
        assert_response :unprocessable_entity
      end
    end
  end

  test "create rejects an over-cap upload before writing anything" do
    file = uploaded_file(filename: "big.png", content_type: "image/png", content: "x" * 64)
    stub_const(DocumentLink::Staging, :MAX_BYTES, 32) do
      assert_no_difference "DocumentLink.count" do
        assert_no_difference -> { Dir.children(@tmp).size } do
          post documents_path, params: { document: file, source: "receipt" }
        end
      end
    end
    assert_response :payload_too_large
  end

  test "create rejects an over-long filename without leaving state behind" do
    # A StringIO keeps the long name in the multipart header only: Rack::Test
    # would otherwise mirror the filename onto disk (ENAMETOOLONG before the
    # request is even built).
    file = Rack::Test::UploadedFile.new(StringIO.new(+"png"), "image/png", true, original_filename: "#{"r" * 260}.png")

    assert_no_difference "DocumentLink.count" do
      assert_no_difference -> { Dir.children(@tmp).size } do
        post documents_path, params: { document: file, source: "receipt" }
      end
    end
    assert_response :unprocessable_entity
  end

  test "create answers 409 when a concurrent upload of the same bytes wins the index" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "race-bytes")
    digest = Digest::SHA256.hexdigest("race-bytes")
    winner = nil
    original = DocumentLink.method(:link_from_upload!)

    DocumentLink.stub(:link_from_upload!, ->(**args) {
      # The window between the controller's exists? check and stage!: a rival
      # upload of the same bytes lands first and takes the unique index.
      winner = DocumentLink.create!(family: @family, created_by: users(:family_admin),
                                    source: "receipt", status: "unlinked", content_sha256: digest)
      original.call(**args)
    }) do
      assert_difference "DocumentLink.count", 1 do
        post documents_path, params: { document: file, source: "receipt" }
      end
    end

    assert_response :conflict
    assert_equal digest, winner.reload.content_sha256
    assert_equal 1, @family.document_links.where(content_sha256: digest).count
    assert_empty Dir.children(@tmp)
  end

  test "file streams the proxied bytes with the range response" do
    Paperless::Client.any_instance.stubs(:file)
                     .with(@link.paperless_document_id, kind: :preview, range: "bytes=0-3")
                     .yields(
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

  test "link refuses a document that is not linkable" do
    @link.update_columns(status: "dismissed")
    post link_document_path(@link), params: { entry_id: entries(:transaction).id }
    assert_response :conflict
    assert_equal "dismissed", @link.reload.status
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

  test "retry refuses a row whose upload is already in flight" do
    # Ruling M4 (M1), 2026-10-10 close-out: staged bytes alone are not enough —
    # a row in `processing`, or one still holding its task id (the poll is
    # scheduled), must not be re-enqueued.
    path = DocumentLink::Staging.write(io: StringIO.new("x"), id: @link.id)
    @link.update_columns(status: "processing", paperless_task_id: "task-1", staged_path: path)
    assert_no_enqueued_jobs do
      post retry_document_path(@link)
    end
    assert_response :conflict

    @link.update_columns(status: "queued", paperless_task_id: "task-1")
    assert_no_enqueued_jobs do
      post retry_document_path(@link)
    end
    assert_response :conflict
    assert_equal "queued", @link.reload.status
  ensure
    DocumentLink::Staging.delete(path)
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
