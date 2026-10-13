require "test_helper"

class DocumentLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("doc-links"))
    @previous_staging = ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"]
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = @tmp.to_s
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @link = document_links(:linked_receipt)
  end

  teardown do
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  # Writes bytes at the store root for the row and returns the path.
  def stage_bytes(link, bytes)
    DocumentLink::Staging.write(io: StringIO.new(bytes), id: link.id)
  end

  test "create rejects an unknown source" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "png")
    assert_no_difference "DocumentLink.count" do
      post documents_path, params: { document: file, source: "bogus" }
    end
    assert_response :unprocessable_entity
  end

  test "create stages the bytes and enqueues the native read" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "png-bytes")
    assert_difference "DocumentLink.count", 1 do
      assert_enqueued_with(job: DocumentUnderstandingJob) do
        post documents_path, params: { document: file, source: "receipt", title: "New" }
      end
    end
    link = DocumentLink.order(:created_at).last
    assert_equal "processing", link.status
    assert link.stored_path.present?
  ensure
    DocumentLink::Staging.delete(link&.stored_path)
  end

  test "create holds the row back to queued with its bytes when the enqueue raises" do
    # Ruling 11 (M1), 2026-10-10 close-out: without this fence a raise between
    # stage! and enqueue strands the row in `processing` — no read is ever
    # started, the retry route refuses `processing`, and the (family, sha256)
    # unique index blocks re-uploading the same bytes.
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "png-bytes")
    DocumentUnderstandingJob.stubs(:perform_later).raises(StandardError, "redis down")
    assert_difference "DocumentLink.count", 1 do
      post documents_path, params: { document: file, source: "receipt" }
    end
    assert_response :redirect
    link = DocumentLink.order(:created_at).last
    assert_equal "queued", link.status
    assert link.stored_path.present?
    assert File.exist?(link.stored_path), "the held row keeps its staged bytes for the retry route"
    assert_equal I18n.t("documents.create.held"), flash[:alert]
  ensure
    DocumentLink::Staging.delete(link&.stored_path)
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

  test "file streams the stored bytes with the range response" do
    @link.update_columns(stored_path: stage_bytes(@link, "%PDF-1.7-range"),
                         content_type: "application/pdf")

    get file_document_path(@link, kind: "preview"), headers: { "Range" => "bytes=0-3" }
    assert_response 206
    assert_equal "application/pdf", response.headers["Content-Type"]
    assert_equal "bytes 0-3/14", response.headers["Content-Range"]
    assert_equal "%PDF", response.body
  end

  test "file serves inline for viewing and an attachment for a download request" do
    @link.update_columns(stored_path: stage_bytes(@link, "%PDF-1.7"),
                         content_type: "application/pdf")

    get file_document_path(@link, kind: "original")
    assert_match(/\Ainline/, response.headers["Content-Disposition"])

    get file_document_path(@link, kind: "original", download: true)
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
  end

  test "file refuses an unknown kind" do
    get file_document_path(@link, kind: "weird")
    assert_response :bad_request
  end

  test "file refuses a document with no stored bytes" do
    processing = document_links(:held_bill)
    processing.update_columns(status: "processing", stored_path: nil)
    get file_document_path(processing, kind: "preview")
    assert_response :not_found
  end

  test "link refuses a document with no stored bytes" do
    processing = document_links(:held_bill)
    processing.update_columns(status: "processing", stored_path: nil)
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
    @link.update_columns(status: "failed")
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf") # -> queued with stored_path
    assert_enqueued_with(job: DocumentUnderstandingJob) do
      post retry_document_path(@link)
    end
    assert_response :redirect
    assert_equal "queued", @link.reload.status
  end

  test "retry refuses a row with no held upload" do
    @link.update_columns(status: "failed", stored_path: nil)
    post retry_document_path(@link)
    assert_response :conflict
  end

  test "retry refuses a row whose read is already in flight" do
    # Staged bytes alone are not enough — a row in `processing` must not be
    # re-enqueued, or a second read would race the first.
    path = DocumentLink::Staging.write(io: StringIO.new("x"), id: @link.id)
    @link.update_columns(status: "processing", stored_path: path)
    assert_no_enqueued_jobs do
      post retry_document_path(@link)
    end
    assert_response :conflict
    assert_equal "processing", @link.reload.status
  ensure
    DocumentLink::Staging.delete(path)
  end

  # -- the one Documents page: the type facet, the grid, what needs you -------
  # (Milestone B, design D1/D3/D5.) The literals the plan sketched asserted the
  # page body contained `documents.source.statement` / `.receipt`; the chip
  # labels "Statements" / "Receipts & Bills" already contain both substrings, so
  # the assertions would pass vacuously (and the "filters to statements only"
  # one could never pass, because the chips always render). These pin the tiles
  # the facet actually filters, which is the behaviour the plan is about.

  test "the page shows statements and receipts together by default" do
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement", title: "Bank statement")

    get documents_path

    assert_response :success
    assert_match document_links(:held_bill).title.to_s, response.body
    assert_match statement.title.to_s, response.body
  end

  test "the type facet filters to statements only" do
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement", title: "Bank statement")

    get documents_path(q: { type: [ "statement" ] })

    assert_response :success
    assert_match statement.title.to_s, response.body
    assert_no_match document_links(:held_bill).title.to_s, response.body
  end

  test "the type chips render All / Statements / Receipts & Bills as a single-select group" do
    get documents_path
    assert_select "input[type='radio'][name='q[type][]'][value=''][checked='checked']"
    assert_select "input[type='radio'][name='q[type][]'][value='statement'][checked='checked']", count: 0
    assert_select "input[type='radio'][name='q[type][]']", count: 3

    get documents_path(q: { type: [ "statement" ] })
    assert_select "input[type='radio'][name='q[type][]'][value='statement'][checked='checked']"
    assert_select "input[type='radio'][name='q[type][]'][value=''][checked='checked']", count: 0
  end

  test "the All chip genuinely clears the type facet" do
    # Review ruling 1: three independent checkboxes let All submit alongside a
    # still-checked type, so All did nothing from a filtered state. A radio
    # group submits exactly one value — the empty one All carries — so it
    # clears. This asserts what the All radio actually submits.
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement", title: "Bank statement")

    get documents_path(q: { type: [ "" ] })

    assert_response :success
    assert_match document_links(:held_bill).title.to_s, response.body
    assert_match statement.title.to_s, response.body
  end

  test "the grid renders each document as a tile keyed by its link" do
    get documents_path

    assert_select "#documents_grid"
    assert_select "#documents_grid #document_link_#{document_links(:unlinked_receipt).id}"
  end

  test "a tile states Reading…, Review and Posted from the link's own fields" do
    reading = document_links(:queued_receipt)
    reading.update_columns(status: "queued", failure_message: nil)
    posted = document_links(:linked_receipt)             # status linked
    review = document_links(:understood_receipt_link)    # understood draft, an account, unpublished

    get documents_path

    assert_select "#document_link_#{reading.id}", text: /#{Regexp.escape(I18n.t("document_browser.tile.states.reading"))}/
    assert_select "#document_link_#{posted.id}", text: /#{Regexp.escape(I18n.t("document_browser.tile.states.posted"))}/
    assert_select "#document_link_#{review.id}", text: /#{Regexp.escape(I18n.t("document_browser.tile.states.review"))}/
  end

  test "a tile whose read did not happen shows why (Needs you, with the reason)" do
    held = document_links(:held_bill)
    held.update_columns(failure_message: "no AI provider is configured")

    get documents_path

    assert_select "#document_link_#{held.id}", text: /#{Regexp.escape(I18n.t("document_browser.tile.states.needs_you"))}/
    assert_select "#document_link_#{held.id}", text: /no AI provider is configured/
  end

  test "a resolved statement with no account asks Which account?" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: nil,
      file: uploaded_file(filename: "ask.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    link = DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                                account_statement: statement, original_filename: "ask.csv")

    get documents_path

    assert_select "#document_link_#{link.id}", text: /#{Regexp.escape(I18n.t("document_browser.tile.states.which_account"))}/
  end

  test "the attention strip counts what needs a person, breaks it down, and offers to show them" do
    held = document_links(:held_bill)
    held.update_columns(failure_message: "no AI provider is configured")
    # A settled draft that resolved without an account is the strip's
    # "needs an account" reason.
    needing = document_links(:unlinked_receipt)
    needing.receipt_imports.first.update_columns(understanding_state: "understood", status: "pending", account_id: nil)

    get documents_path

    assert_response :success
    assert_match I18n.t("document_browser.attention.title", count: DocumentLink.needs_attention(@family).count),
                 response.body
    assert_select "#documents_attention", text: /#{Regexp.escape(I18n.t("document_browser.attention.reasons.couldnt_read", count: 1))}/
    assert_select "#documents_attention", text: /#{Regexp.escape(I18n.t("document_browser.attention.reasons.needs_account", count: 1))}/
    assert_select "#documents_attention a[href='#{documents_path(q: { attention: 1 })}']"
  end

  test "the attention filter narrows the grid to exactly the documents that need a person" do
    held = document_links(:held_bill)
    held.update_columns(failure_message: "no AI provider is configured")

    get documents_path(q: { attention: 1 })

    assert_response :success
    assert_match held.title.to_s, response.body
    assert_no_match document_links(:linked_receipt).title.to_s, response.body
  end

  test "the attention strip renders nothing when no document needs a person" do
    DocumentLink.where(family: @family).where.not(failure_message: nil).update_all(failure_message: nil)
    # receipt_understood is the only understood draft; completing it clears the
    # second branch of needs_attention.
    imports(:receipt_understood).update!(status: "complete")

    get documents_path

    assert_response :success
    assert_select "#documents_attention", count: 0
  end

  # -- the viewer modal (M8 Task 4) -------------------------------------------

  test "index rows link into the viewer carrying the page's filters" do
    get documents_path(source: "bill")

    assert_response :success
    # `viewer_params` rides in the URL, so the modal's prev/next recompute over
    # the same filtered list the index listed.
    assert_select "a[href='#{viewer_document_path(document_links(:held_bill), source: "bill")}']"
  end

  test "the viewer renders a pdf iframe over the proxy for a settled pdf" do
    link = document_links(:linked_receipt)
    get viewer_document_path(link)

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "iframe[src='#{file_document_path(link, kind: "original")}']"
  end

  test "the viewer renders a lightbox image for a photo" do
    get viewer_document_path(document_links(:unlinked_receipt))
    assert_select "img[data-document-viewer-target='image'][src='#{file_document_path(document_links(:unlinked_receipt), kind: "original")}']"
    assert_select "[data-action~='wheel->document-viewer#zoom']"
  end

  # The document's own page (Milestone B Task 4) is the stable, shareable URL
  # (`Row#details_url`). The modal is the way in from the grid, so the viewer
  # must offer the link out -- otherwise the page is reachable only by typing
  # the URL (review finding 4).
  test "the viewer offers the document's own page" do
    link = document_links(:understood_receipt_link)
    get viewer_document_path(link)

    assert_response :success
    assert_select "a[href='#{document_path(link)}']"
  end

  test "an image row's file url serves the stored image bytes" do
    # end to end through the real store: the row's file URL fetches the
    # document's own bytes with their stored content type.
    link = document_links(:unlinked_receipt) # image/png
    link.update_columns(stored_path: stage_bytes(link, "PNGBYTES"))
    row = DocumentBrowser::Row.for_document_link(link)

    get row.file_url

    assert_response :success
    assert_equal "image/png", response.headers["Content-Type"]
    assert_equal "PNGBYTES", response.body
  end

  test "a pdf row's file url still serves a pdf" do
    link = document_links(:linked_receipt) # application/pdf
    link.update_columns(stored_path: stage_bytes(link, "%PDF-1.7"))
    row = DocumentBrowser::Row.for_document_link(link)

    get row.file_url

    assert_response :success
    assert_equal "application/pdf", response.headers["Content-Type"]
  end

  test "the viewer states a missing copy honestly instead of framing it" do
    get viewer_document_path(document_links(:queued_receipt))

    assert_response :success
    # (adapted 2026-10-11, Task 4) the fence's `assert_no_selector` / `assert_text`
    # are Capybara helpers and do not exist in an ActionDispatch::IntegrationTest;
    # the integration equivalents pin the same two things at equal strength.
    assert_select "iframe", count: 0
    assert_match I18n.t("document_browser.viewer.unavailable_title"), response.body
  end

  test "the viewer computes prev/next over the filtered list" do
    # (repaired 2026-10-11, verifier F3) no fixture row pins created_at, so
    # EVERY row the default receipt|bill filter can see is pinned here —
    # pinning only the asserted pair left the load-time rows (held_bill,
    # queued_receipt, understood_receipt_link) sorting ahead of `newer`, which
    # made its "nothing newer" assertion false.
    older = document_links(:unlinked_receipt)
    newer = document_links(:linked_receipt)
    document_links(:held_bill).update_columns(created_at: 3.days.ago)
    document_links(:queued_receipt).update_columns(created_at: 4.days.ago)
    document_links(:understood_receipt_link).update_columns(created_at: 5.days.ago)
    older.update_columns(created_at: 2.days.ago)
    newer.update_columns(created_at: 1.day.ago)

    get viewer_document_path(newer)
    assert_select "a[data-viewer-next][href='#{viewer_document_path(older)}']"
    assert_select "a[data-viewer-previous]", count: 0 # newest row: nothing newer

    # The mirror makes the walk discriminating in both directions.
    get viewer_document_path(older)
    assert_select "a[data-viewer-previous][href='#{viewer_document_path(newer)}']"
    assert_select "a[data-viewer-next][href='#{viewer_document_path(document_links(:held_bill))}']"
  end

  test "an id outside the family's links is a 404, never a leak" do
    # (Ruling M8-C4, 2026-10-11 close-out) a REAL foreign-family row, not a
    # random UUID: this id exists, so without family scoping `set_link` would
    # find it and the viewer would render it — the 404 is discriminating.
    foreign = DocumentLink.create!(family: families(:empty), created_by: users(:empty),
                                   source: "receipt", status: "unlinked",
                                   title: "Foreign receipt", original_filename: "foreign.png",
                                   content_type: "image/png")

    get viewer_document_path(foreign)
    assert_response :not_found

    # The random-UUID shape stays as an extra: a stale id dies at the same gate.
    get viewer_document_path(SecureRandom.uuid)
    assert_response :not_found
  end

  test "destroy is refused while an entry this document produced is unreconciled, and names it" do
    # @link is document_links(:linked_receipt); its entry is entries(:transaction),
    # unreconciled by default. Spec N9: money is never silently cascaded.
    @link.entry.update!(reconciled_at: nil)

    assert_no_difference "DocumentLink.count" do
      delete document_path(@link)
    end
    assert_nil @link.reload.deleted_at, "a refused delete writes nothing"
    assert_redirected_to documents_path
    assert_match @link.entry.name, flash[:alert],
                 "the refusal must NAME what is in the way, not just refuse"
  end

  test "destroy tombstones the row and removes its staged bytes once the money is settled" do
    @link.entry.update!(reconciled_at: Time.current)
    DocumentLink::Staging.write(io: StringIO.new("x"), id: @link.id)
    @link.update_columns(stored_path: DocumentLink::Staging.root.join(@link.id).to_s)
    path = @link.reload.stored_path

    assert_no_difference "DocumentLink.count" do
      delete document_path(@link)
    end

    assert_not_nil @link.reload.deleted_at, "the row survives as a tombstone"
    assert_not File.exist?(path), "the bytes are gone"
    assert_redirected_to documents_path
    assert_equal I18n.t("documents.destroy.removed"), flash[:notice]
  end

  test "destroy leaves a tombstone out of the archive" do
    @link.entry.update!(reconciled_at: Time.current)
    delete document_path(@link)

    get documents_path
    assert_response :success
    assert_no_match @link.title, response.body,
                    "a soft-deleted document must not appear in the Documents grid"
  end
end
