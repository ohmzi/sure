require "test_helper"

class DocumentLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("doc-links"))
    @previous_staging = ENV["SURE_DOCUMENT_STORE_DIR"]
    ENV["SURE_DOCUMENT_STORE_DIR"] = @tmp.to_s
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @link = document_links(:linked_receipt)
  end

  teardown do
    ENV["SURE_DOCUMENT_STORE_DIR"] = @previous_staging
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

  test "file serves a PDF's rendered preview for the thumb kind" do
    @link.update_columns(stored_path: stage_bytes(@link, "%PDF-1.7"),
                         content_type: "application/pdf")
    preview = @tmp.join("preview.png")
    File.binwrite(preview, "\x89PNG\r\n\x1a\nrendered-page-one")
    DocumentLink::Thumbnail.stubs(:path_for).returns(preview)

    get file_document_path(@link, kind: "thumb")

    assert_response :success
    assert_equal "image/png", response.headers["Content-Type"]
    assert_equal "\x89PNG\r\n\x1a\n".b, response.body.b[0, 8], "the preview, not the PDF"
    assert_match(/\Ainline/, response.headers["Content-Disposition"])
  end

  test "file answers 404 for a PDF whose preview cannot be rendered" do
    # The bytes are a PDF, so they are not a substitute for a picture: handing
    # them to an <img> would be a broken image. The tile keeps its type icon.
    @link.update_columns(stored_path: stage_bytes(@link, "%PDF-1.7"),
                         content_type: "application/pdf")
    DocumentLink::Thumbnail.stubs(:path_for).returns(nil)

    get file_document_path(@link, kind: "thumb")

    assert_response :not_found
    assert_equal "no preview", response.body
  end

  # One page of a PDF as a picture (2026-10-17): a phone shows the pages in the
  # app instead of leaving it for the browser's PDF viewer.
  test "file serves one page of a PDF as a PNG, and 404s a page that is not there" do
    @link.update_columns(stored_path: stage_bytes(@link, "%PDF-1.7"), content_type: "application/pdf")
    page = @tmp.join("page-2.png")
    File.binwrite(page, "\x89PNG\r\n\x1a\npage-two")
    DocumentLink::PageImage.any_instance.stubs(:path).returns(page)

    get file_document_path(@link, kind: "page", page: 2)

    assert_response :success
    assert_equal "image/png", response.headers["Content-Type"]
    assert_match(/\Ainline/, response.headers["Content-Disposition"])

    DocumentLink::PageImage.any_instance.stubs(:path).returns(nil)
    get file_document_path(@link, kind: "page", page: 99)
    assert_response :not_found
  end

  test "the viewer shows a PDF's pages as pictures for a phone, with a download" do
    @link.update_columns(stored_path: stage_bytes(@link, "%PDF-1.7"), content_type: "application/pdf", page_count: 3)

    get viewer_document_path(@link)

    assert_response :success
    assert_select "[data-document-pages='3'] img[src*='kind=page']", count: 3
    assert_select "[data-document-pages] img[src*='page=3']"
    assert_select "[data-document-pages].lg\\:hidden", count: 1
  end

  # Opened from a transaction (the owner, 2026-10-17), the viewer is about that
  # transaction: its line in the statement, the page with the line marked, and
  # how it got into the account. The statement's own read folds away below.
  test "the viewer opened from a transaction shows its line, marked on its page" do
    import = statement_import_reading("Customer Transfer to 254724***228 - WANJUHI NJOROGE", "-3700.00")
    entry = create_statement_entry(import, name: "Customer Transfer to 254724***228 - WANJUHI NJOROGE", amount: 3700)

    get viewer_document_path(import.document_link, entry_id: entry.id)

    assert_response :success
    assert_select "[data-document-trace='created']"
    assert_select "[data-trace-line]", text: /WANJUHI NJOROGE/
    assert_select "[data-page='1'] [data-document-mark]"
    assert_select "[data-document-pages]:not(.lg\\:hidden)"
    assert_select "details[data-document-about]"
  end

  # A cold viewer open derives both facts in one request: the line locator runs
  # pdftotext's text layer, and the pages gallery runs pdfinfo. The request cache
  # memoizes both, so their keys must not collide — an HTML String and a page
  # Integer under one key blanks the gallery or 500s the trace (P1.12 fix round).
  test "a cold viewer open reads the text layer and the page count without colliding" do
    import = statement_import_reading("Customer Transfer to 254724***228 - WANJUHI NJOROGE", "-3700.00")
    link = import.document_link
    link.update_columns(page_count: nil)
    entry = create_statement_entry(import, name: "Customer Transfer to 254724***228 - WANJUHI NJOROGE", amount: 3700)

    original = Open3.method(:capture2)
    pdfinfo_calls = 0
    counting = lambda do |*args|
      pdfinfo_calls += 1 if args.first == "pdfinfo"
      original.call(*args)
    end

    Open3.stub(:capture2, counting) do
      get viewer_document_path(link, entry_id: entry.id)
    end

    assert_response :success
    assert_select "[data-document-pages='3'] img[src*='kind=page']", { count: 3 },
                  "the cold page count must not be poisoned by the text layer"
    assert_select "[data-page='1'] [data-document-mark]", { minimum: 1 },
                  "the text layer still locates the line"
    assert_equal 3, link.reload.page_count, "pdfinfo's count is recorded on the row"
    assert_equal 1, pdfinfo_calls

    DocumentLink::RequestCache.reset # a later request
    Open3.stub(:capture2, counting) do
      get viewer_document_path(link, entry_id: entry.id)
    end

    assert_response :success
    assert_equal 1, pdfinfo_calls, "the recorded count means pdfinfo is not run again"
  end

  test "the viewer ignores a transaction the document has nothing to do with" do
    import = statement_import_reading("Customer Transfer to 254724***228 - WANJUHI NJOROGE", "-3700.00")

    get viewer_document_path(import.document_link, entry_id: entries(:transaction_entry).id)

    assert_response :success
    assert_select "[data-document-trace]", count: 0
    assert_select "[data-document-mark]", count: 0
  end

  test "the viewer never traces another family's transaction" do
    import = statement_import_reading("Customer Transfer to 254724***228 - WANJUHI NJOROGE", "-3700.00")
    elsewhere = Account.create!(family: families(:empty), name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)
    other = Entry.create!(account: elsewhere, name: "x", date: Date.current, currency: "USD", amount: 3700,
                          entryable: Transaction.new, import: import)

    get viewer_document_path(import.document_link, entry_id: other.id)

    assert_response :success
    assert_select "[data-document-trace]", count: 0
  end

  test "file serves an image's own bytes for the thumb kind, rendering nothing" do
    @link.update_columns(stored_path: stage_bytes(@link, "png-bytes"),
                         content_type: "image/png")
    DocumentLink::Thumbnail.expects(:path_for).never

    get file_document_path(@link, kind: "thumb")

    assert_response :success
    assert_equal "image/png", response.headers["Content-Type"]
    assert_equal "png-bytes", response.body
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

  # Spec §6: "Retry with local model" / "Retry with online AI" each re-run the
  # read on that rung only.
  test "retry with a reader re-reads the document with that reader" do
    @link.update_columns(status: "failed")
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf")

    assert_enqueued_with(job: DocumentUnderstandingJob, args: [ @link.id, "online", nil ]) do
      post retry_document_path(@link, reader: "online")
    end
  end

  test "retry with an unknown reader re-reads with the automatic ladder" do
    @link.update_columns(status: "failed")
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf")

    assert_enqueued_with(job: DocumentUnderstandingJob, args: [ @link.id, "auto", nil ]) do
      post retry_document_path(@link, reader: "anything")
    end
  end

  # Review finding I6: a settled document is not re-read from here — its rows
  # may be importing or posted, and no screen offers it.
  test "retry refuses a settled document" do
    @link.update_columns(status: "failed", entry_id: nil)
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf")
    @link.update_columns(status: "unlinked")

    assert_no_enqueued_jobs do
      post retry_document_path(@link, reader: "online")
    end
    assert_response :conflict
  end

  test "reprocess re-reads a settled document with a forced class" do
    @link.update_columns(status: "failed")
    @link.stage!(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf")
    @link.update_columns(status: "unlinked")

    assert_enqueued_with(job: DocumentUnderstandingJob, args: [ @link.id, "auto", "statement" ]) do
      post reprocess_document_path(@link, document_class: "statement")
    end

    assert_response :redirect
    assert_equal "queued", @link.reload.status
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

  # (Documents redesign, 2026-10-16) The radio group became the iOS segmented
  # control: three links, exactly one current, each to exactly one type — still
  # single-select, so All still genuinely clears the facet.
  test "the type segments render All / Statements / Receipts & Bills as a single-select group" do
    get documents_path
    assert_select "[data-controller~='segmented-slide']" do
      assert_select "a", count: 3
      assert_select "a[aria-current='true']", count: 1
      assert_select "a[aria-current='true'][href='#{documents_path}']", text: I18n.t("document_browser.filters.types.all")
    end
    assert_select "input[type='hidden'][name='q[type][]']", count: 0

    get documents_path(q: { type: [ "statement" ] })
    assert_select "[data-controller~='segmented-slide'] a[aria-current='true']", count: 1
    assert_select "[data-controller~='segmented-slide'] a[aria-current='true'][href='#{documents_path(q: { type: [ "statement" ] })}']"
    # The chosen type rides along with a search or Show results.
    assert_select "input[type='hidden'][name='q[type][]'][value='statement']"
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

  test "a statement that needs an account is counted in the strip and given an action in the viewer" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: nil,
      file: uploaded_file(filename: "needs_account.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    link = DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                                account_statement: statement, original_filename: "needs_account.csv")

    get documents_path

    assert_select "#documents_attention",
                  text: /#{Regexp.escape(I18n.t("document_browser.attention.reasons.needs_account", count: 1))}/

    get viewer_document_path(link)

    # The tile's "Which account?" leads nowhere; this is the working affordance,
    # and it points at the statement page's picker.
    assert_select "a[href='#{account_statement_path(statement)}']"
  end

  # Spec §6: the fix is on the tile itself, not three clicks away — the owner's
  # June statement sat on "Which account?" with no way to act from the grid.
  test "a statement tile that needs an account offers the account picker inline" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: nil,
      file: uploaded_file(filename: "needs_account.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    link = DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                                account_statement: statement, original_filename: "needs_account.csv")

    get documents_path

    accessible = users(:family_admin).accessible_accounts.visible
    assert_select "##{ActionView::RecordIdentifier.dom_id(link)}" do
      assert_select "form[action='#{link_account_statement_path(statement)}']" do
        assert_select "input[type='hidden'][name='account_id']"
        assert_select "[data-select-target='option'][data-value='#{accounts(:credit_card).id}']"
        # Only the accounts the signed-in person can reach (plus the blank prompt).
        assert_select "[data-select-target='option']", accessible.count + 1
        assert_select "button[type='submit']"
      end
    end
  end

  test "a held tile shows why and offers the retries its hold allows" do
    link = document_links(:held_bill)
    link.update_columns(failure_message: "DeepSeek is overloaded right now. Nothing was imported.")
    DocumentExtraction.record!(
      document_link: link, status: "failed", error: link.failure_message,
      validations: { "hold" => { "step" => "read", "code" => "all_readers_failed",
                                 "message" => link.failure_message, "actions" => %w[retry_local retry_online] } }
    )

    get documents_path

    assert_select "##{ActionView::RecordIdentifier.dom_id(link)}" do
      assert_select "*", text: /DeepSeek is overloaded right now/
      assert_select "form[action='#{retry_document_path(link, reader: "local")}']"
      assert_select "form[action='#{retry_document_path(link, reader: "online")}']"
    end
  end

  test "a duplicate statement's tile offers Delete and nothing else" do
    link = document_links(:held_bill)
    link.update_columns(failure_message: "Duplicate of june.pdf")
    DocumentExtraction.record!(
      document_link: link, status: "succeeded",
      validations: { "hold" => { "step" => "check", "code" => "statement_duplicate",
                                 "message" => "Duplicate of june.pdf", "actions" => %w[delete] } }
    )

    get documents_path

    assert_select "##{ActionView::RecordIdentifier.dom_id(link)}" do
      assert_select "form[action='#{document_path(link)}'] input[name='_method'][value='delete']"
      assert_select "form[action*='retry']", 0
    end
  end

  test "the duplicate review flags copies whose printed balances disagree" do
    first_statement = statement_for_period(Date.new(2026, 6, 12), Date.new(2026, 7, 10),
                                           opening: 1000, closing: 1200)
    second_statement = statement_for_period(Date.new(2026, 6, 12), Date.new(2026, 7, 10),
                                            opening: 1000, closing: 1300)
    link = document_link_for(first_statement)
    document_link_for(second_statement)

    get viewer_document_path(link)

    assert_response :success
    assert_match I18n.t("documents.understanding.duplicates.balance_mismatch"), response.body
  end

  test "the viewer shows a hold's reason and its actions" do
    link = document_links(:held_bill)
    link.update_columns(failure_message: "DeepSeek is overloaded right now. Nothing was imported.")
    DocumentExtraction.record!(
      document_link: link, status: "failed", error: link.failure_message,
      validations: { "hold" => { "step" => "read", "code" => "all_readers_failed",
                                 "message" => link.failure_message, "actions" => %w[retry_online] } }
    )

    get viewer_document_path(link)

    assert_select "[data-document-hold]" do
      assert_select "form[action='#{retry_document_path(link, reader: "online")}']"
    end
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

  test "the attention strip counts a statement with no period and links to fix it" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: accounts(:depository),
      file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 no period")
    )
    statement.update_columns(period_start_on: nil, period_end_on: nil)
    document_link_for(statement)

    get documents_path

    assert_response :success
    assert_select "#documents_attention",
                  text: /#{Regexp.escape(I18n.t("document_browser.attention.reasons.missing_period", count: 1))}/
    assert_select "#documents_attention a[href='#{account_statements_path(q: { attention: "missing_period" })}']"

    get documents_path(q: { attention: 1 })
    assert_match statement.filename, response.body
  end

  test "the attention strip counts a statement with no printed identity and links to fix it" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: accounts(:depository),
      file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 no identity")
    )
    statement.update_columns(
      period_start_on: Date.new(2026, 5, 1),
      period_end_on: Date.new(2026, 5, 31),
      account_last4_hint: nil, institution_name_hint: nil, account_name_hint: nil,
      sanitized_parser_output: {}
    )
    document_link_for(statement)

    get documents_path

    assert_response :success
    assert_select "#documents_attention",
                  text: /#{Regexp.escape(I18n.t("document_browser.attention.reasons.missing_identity", count: 1))}/
    assert_select "#documents_attention a[href='#{account_statements_path(q: { attention: "missing_identity" })}']"
  end

  test "the viewer surfaces a stored period that disagrees with the filename" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: accounts(:depository),
      file: uploaded_file(
        filename: "statement-2026-05-09-to-2026-06-08.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 period mismatch"
      )
    )
    statement.update_columns(
      period_start_on: Date.new(2026, 6, 1), period_end_on: Date.new(2026, 6, 30),
      account_last4_hint: nil, institution_name_hint: nil, account_name_hint: nil,
      sanitized_parser_output: {}
    )
    link = document_link_for(statement)

    get viewer_document_path(link)

    assert_response :success
    assert_match I18n.t("account_statements.period_check.title"), response.body
    assert_match(/does not match the filename period/, response.body)
    assert_select "a[href='#{account_statement_path(statement)}'][aria-label='#{I18n.t("document_browser.row.fix_statement_details")}']"
  end

  test "attention metadata counts stay inside the family" do
    foreign_family = families(:empty)
    foreign = AccountStatement.create_from_upload!(
      family: foreign_family, account: nil,
      file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 foreign")
    )
    foreign.update_columns(period_start_on: nil, period_end_on: nil)
    foreign_link = DocumentLink.create!(family: foreign_family, source: "statement", status: "unlinked",
                                        account_statement: foreign, original_filename: "statement.pdf")

    assert_not_includes DocumentLink.needs_attention(@family), foreign_link
    assert_equal 0, DocumentsAttentionComponent.new(family: @family).missing_period
    assert_equal 0, DocumentsAttentionComponent.new(family: @family).missing_printed_identity
  end

  test "the attention strip renders nothing when no document needs a person" do
    DocumentLink.where(family: @family).where.not(failure_message: nil).update_all(failure_message: nil)
    # receipt_understood is the only understood draft; completing it clears the
    # second branch of needs_attention. Pending imports that came from a
    # document are the third ask (the ledger is waiting), so complete those too.
    imports(:receipt_understood).update!(status: "complete")
    @family.imports.where(status: "pending").where.not(document_link_id: nil).update_all(status: "complete")

    get documents_path

    assert_response :success
    assert_select "#documents_attention", count: 0
  end

  # -- the viewer modal (M8 Task 4) -------------------------------------------

  test "the documents grid shows each duplicate group's count from one batched query" do
    statement_for = lambda do |period_end_on|
      content = file_fixture("imports/sample_bank_statement.pdf").binread
      AccountStatement.new(
        family: @family, account: accounts(:depository),
        filename: "dupe-#{SecureRandom.hex(4)}.pdf", content_type: "application/pdf",
        checksum: SecureRandom.hex, content_sha256: SecureRandom.hex(32), byte_size: content.bytesize,
        period_start_on: Date.new(2026, 6, 1), period_end_on: period_end_on
      ).tap do |statement|
        statement.original_file.attach(io: StringIO.new(content), filename: "dupe.pdf",
                                       content_type: "application/pdf")
        statement.save!
      end
    end
    copies = 3.times.map { statement_for.call(Date.new(2026, 6, 30)) } +
             2.times.map { statement_for.call(Date.new(2026, 7, 31)) }
    copies.each do |statement|
      DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                           original_filename: "dupe.pdf", content_type: "application/pdf",
                           account_statement: statement)
    end

    queries = capture_sql_queries { get documents_path }

    assert_response :success
    assert_equal 3, response.body.scan("2 duplicates").size
    assert_equal 2, response.body.scan(/\b1 duplicate\b/).size
    grouped_counts = queries.select do |sql|
      sql.include?('GROUP BY "account_statements"."account_id"') && !sql.include?("HAVING")
    end
    assert_equal 1, grouped_counts.size, "duplicate counts are one grouped query for the page"
    assert_empty queries.grep(/"document_links"\."id" !=/),
                 "no per-row duplicate COUNT"
  end

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
  test "the viewer shows how a document was read, reader by reader" do
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "DeepSeek", model: "deepseek-flash", page_count: 1, status: "succeeded",
      verdict: { "document_class" => "receipt", "total" => "12.34" },
      validations: { "read_attempts" => [
        { "reader" => "the local model (qwen2.5vl:7b)", "outcome" => "skipped_busy", "seconds" => 0 },
        { "reader" => "DeepSeek", "outcome" => "read", "seconds" => 40.2 }
      ] }
    )

    get viewer_document_path(link)

    assert_select "[data-read-history]" do
      assert_select "[data-read-attempt]", 2
      assert_select "[data-read-attempt]", text: /The local model \(qwen2.5vl:7b\).*Skipped: the GPU was busy/m
      assert_select "[data-read-attempt]", text: /DeepSeek.*Read it.*40s/m
    end
  end

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

  test "destroy returns to the duplicate review when asked" do
    @link.entry.update!(reconciled_at: Time.current)

    delete document_path(@link, return_to: documents_path(q: { duplicates: 1 }))

    assert_redirected_to documents_path(q: { duplicates: 1 })
    assert_not_nil @link.reload.deleted_at
  end

  test "destroy refuses an off-site return_to" do
    @link.entry.update!(reconciled_at: Time.current)

    delete document_path(@link, return_to: "//evil.example/phish")

    assert_redirected_to documents_path
  end

  test "destroy leaves a tombstone out of the archive" do
    @link.entry.update!(reconciled_at: Time.current)
    delete document_path(@link)

    get documents_path
    assert_response :success
    assert_no_match @link.title, response.body,
                    "a soft-deleted document must not appear in the Documents grid"
  end
  private
    def statement_import_reading(name, amount)
      statement = AccountStatement.create_from_upload!(
        family: @family, account: accounts(:depository),
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf",
                            content: file_fixture("imports/sample_bank_statement.pdf").binread)
      )
      statement.archive_document_link!
      import = PdfImport.create_from_statement!(statement: statement.reload)
      import.update!(extracted_data: { "transactions" => [ { "date" => Date.current.iso8601, "amount" => amount, "name" => name } ] })
      link = import.document_link
      link.update_columns(stored_path: stage_bytes(link, file_fixture("imports/sample_bank_statement.pdf").binread),
                          content_type: "application/pdf", page_count: 3)
      import
    end

    def create_statement_entry(import, name:, amount:)
      Entry.create!(account: accounts(:depository), name: name, date: Date.current, currency: "USD", amount: amount,
                    entryable: Transaction.new, import: import)
    end

    def statement_for_period(start_on, end_on, opening:, closing:)
      content = file_fixture("imports/sample_bank_statement.pdf").binread
      statement = AccountStatement.new(
        family: @family, account: accounts(:depository),
        filename: "statement_#{SecureRandom.hex(4)}.pdf", content_type: "application/pdf",
        checksum: SecureRandom.hex, content_sha256: SecureRandom.hex(32), byte_size: content.bytesize,
        period_start_on: start_on, period_end_on: end_on,
        opening_balance: opening, closing_balance: closing
      )
      statement.original_file.attach(io: StringIO.new(content), filename: statement.filename,
                                     content_type: "application/pdf")
      statement.save!
      statement
    end

    def document_link_for(statement)
      DocumentLink.create!(family: @family, source: "statement", status: "unlinked",
                           original_filename: statement.filename, content_type: statement.content_type,
                           account_statement: statement)
    end
end
