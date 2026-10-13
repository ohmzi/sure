require "test_helper"

class DocumentsArchiveTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("archive"))
    @previous_staging = ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"]
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = @tmp.to_s
    sign_in users(:family_admin)
  end

  teardown do
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  test "the receipts and bills page renders in the main chrome, never the settings chrome" do
    get documents_path
    assert_response :success
    assert_select "#settings-nav-container", count: 0                     # settings layout absent
    assert_select "div[data-controller~='app-layout']"                    # main chrome present
    assert_select "a[href='#{transactions_path}']"                        # and the main nav with it
    assert_select "h1", text: I18n.t("documents.index.title") # the page owns its title now (one Documents page)
  end

  test "the page shows every type by default, and the type facet narrows and widens" do
    # (Milestone B, design D1) The unified page is one list — statements and
    # receipts together by default; the type is an in-page chip, not a source
    # default.
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement", title: "A statement document")

    get documents_path
    assert_match document_links(:held_bill).title.to_s, response.body
    assert_match statement.title.to_s, response.body

    get documents_path(q: { type: %w[statement] })
    assert_match statement.title.to_s, response.body
    assert_no_match document_links(:held_bill).title.to_s, response.body

    get documents_path(q: { type: [ "receipt,nope" ] }) # unknown tokens are dropped
    assert_response :success
    assert_no_match statement.title.to_s, response.body
  end

  test "the archive lists the family's documents as tiles with their state" do
    get documents_path
    assert_response :success
    # Only images carry a thumbnail (their own stored bytes); the PDF next to it
    # renders its file-type icon instead, and a linked document reads "Posted"
    # — the design's tile state, not the raw link status.
    assert_select "img[src=?]", file_document_path(document_links(:unlinked_receipt), kind: "thumb")
    assert_match I18n.t("document_browser.tile.states.posted"), response.body
  end

  test "the browser lists tiles with thumbnails, statuses and no action row" do
    get documents_path
    assert_select "img[src=?]", file_document_path(document_links(:unlinked_receipt), kind: "thumb")
    assert_match I18n.t("documents.status.linked"), response.body
    # The tile is purely visual now (Milestone B Task 4): the document's
    # affordances (Review details / Reading… / Retry / Remove) moved into the
    # viewer, so none renders on the grid.
    assert_select "#documents_grid a[href='#{import_path(imports(:receipt_understood))}']", count: 0
    assert_select "#documents_grid button[disabled]", count: 0
  end

  test "the draft affordances live in the viewer now, not the tile" do
    # (Milestone B Task 4) The tile's action row was absorbed by the viewer:
    # Review details / Reading… / Retry / Remove are reached from the document
    # itself, so a tile is a picture and nothing else. This is the receipt_draft
    # row: awaiting_ocr keeps the VISIBLE disabled "Reading…" affordance (the old
    # `if enabled` dropped it and left the label dead).
    assert I18n.exists?("imports.receipt_import.reading")
    assert I18n.exists?("imports.receipt_import.review_details")
    # add_details is the needs_understanding row's label (no fixture reaches that
    # state here); pin it explicitly so dropping the key cannot go unnoticed.
    assert I18n.exists?("imports.receipt_import.add_details")

    draft = imports(:receipt_draft)
    get viewer_document_path(draft.document_link)
    assert_response :success
    assert_select "button[disabled]" # the Reading… affordance renders

    get viewer_document_path(imports(:receipt_understood).document_link)
    assert_select "a[href='#{import_path(imports(:receipt_understood))}']" # the enabled Review details link
  end

  test "pagination pages the list" do
    family = families(:dylan_family)
    11.times do |i|
      DocumentLink.create!(family: family, created_by: users(:family_admin), source: "receipt",
                           title: "Paged receipt #{i}", original_filename: "paged-#{i}.png",
                           status: "unlinked", content_sha256: format("%064d", i + 1))
    end

    get documents_path(per_page: 10)
    assert_response :success
    assert_select "#document-browser [id^='document_link_']", count: 10 # page 1 is full
    assert_select "nav a[href*='page=2']"                               # the shared pagination partial renders

    get documents_path(per_page: 10, page: 2)
    assert_response :success
    # The remainder: every visible row (11 created above + the receipt/bill
    # fixtures) minus the 10 page 1 carried — computed, not hard-coded.
    assert_select "#document-browser [id^='document_link_']", count: family.document_links.count - 10
  end

  test "the archive is readable by guests" do
    sign_in family_guest
    get documents_path
    assert_response :success # read-only view is fine for guests
  end

  test "the archive renders the dropzone controller and its append target" do
    get documents_path
    # The page IS the dropzone (design D2): the controller is mounted over the
    # whole archive with the ONE intake endpoint as its URL value.
    assert_select "[data-controller~='document-dropzone'][data-document-dropzone-url-value='#{documents_intake_path}']"
    # The picker's change is what uploads a chosen file
    # (document_dropzone_controller#pick) — pin the wiring so a dead dropzone
    # can never pass this test again.
    assert_select "input[type='file'][data-action~='change->document-dropzone#pick']"
    # The intake stream appends into #documents_grid and reports refusals into
    # #documents_intake_status; both must exist for the flow to work.
    assert_select "#documents_grid"
    assert_select "#documents_intake_status"
    # The bar's copy reaches the page (not a "Translation missing:" fallback).
    assert_select "label", text: I18n.t("documents.intake_bar.add_document")
  end

  test "a failed document surfaces its failure message on the card" do
    link = document_links(:queued_receipt)
    link.update_columns(status: "failed", failure_message: "no text layer")
    get documents_path
    assert_response :success
    assert_match "no text layer", response.body
  end

  test "a duplicate sha256 warns and never re-adds" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "k")
    post documents_path, params: { document: file, source: "receipt" }
    assert_response :redirect

    dup = uploaded_file(filename: "r2.png", content_type: "image/png", content: "k")
    assert_no_difference "DocumentLink.count" do
      post documents_path, params: { document: dup, source: "receipt" }
    end
    assert_response :conflict
  ensure
    DocumentLink.find_each { |link| DocumentLink::Staging.delete(link.stored_path) }
  end

  test "a blank source defaults to receipt, leaving the class to the read" do
    file = uploaded_file(filename: "bank-statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 x")
    post documents_path, params: { document: file } # no source: the dropzone's default

    link = DocumentLink.order(:created_at).last
    assert_equal "receipt", link.source
  ensure
    DocumentLink.find_each { |link| DocumentLink::Staging.delete(link.stored_path) }
  end

  # -- full-text search, sort and the document-date range (M8 Task 5; the moved
  #    M7 Task 10 fences, adapted to the browser) -------------------------------

  test "search matches the OCR snapshot as well as title and filename" do
    document_links(:unlinked_receipt).update!(title: "Weekly shop", extracted_text: "LATTE LANE CAFE\nTOTAL 12.00")

    get documents_path(q: { search: "latte lane" })
    assert_match "Weekly shop", response.body

    get documents_path(q: { search: "weekly" }) # title fallback
    assert_match "Weekly shop", response.body

    get documents_path(q: { search: "nothing-here" })
    assert_no_match "Weekly shop", response.body
  end

  test "a literal percent sign matches only rows that contain one" do
    document_links(:unlinked_receipt).update!(title: "5% cashback receipt")
    document_links(:queued_receipt).update!(title: "New receipt")

    get documents_path(q: { search: "%" })

    assert_response :success
    assert_match "5% cashback receipt", response.body
    assert_no_match "New receipt", response.body
  end

  test "search applies within the type filter" do
    held = document_links(:held_bill)
    held.update!(extracted_text: "WATER UTILITY DISTRICT")
    document_links(:unlinked_receipt).update!(extracted_text: "WATER", title: "Water receipt")

    get documents_path(q: { type: [ "receipt,bill" ], search: "water" })
    assert_response :success # both rows are in receipt,bill

    get documents_path(q: { type: [ "bill" ], search: "water" })
    assert_no_match "Water receipt", response.body
  end

  test "the archive and its search read no stored bytes" do
    # The index is a metadata read: it renders store URLs, never the bytes.
    DocumentLink::Staging.expects(:open).never
    DocumentLink::Staging.expects(:write).never

    get documents_path(q: { type: [ "receipt,bill" ], search: "coffee" })
    assert_response :success
  end

  test "a malformed scalar q param renders the page instead of a 500" do
    # (Ruling M8-C6, 2026-10-11 close-out) `?q=coffee` and `?q[]=coffee` send
    # a scalar/array where the facet hash belongs; the concern's shape guard
    # wraps them empty instead of raising out of #permit.
    get documents_path(q: "coffee")
    assert_response :success

    get documents_path(q: [ "coffee" ])
    assert_response :success
  end

  test "sort orders by document date and by name" do
    old = document_links(:unlinked_receipt)
    old.update!(title: "Alpha receipt")
    # The understood draft's link (understood_receipt_link, title "Latte Lane")
    # gets a parsed date NEWER than every fallback (created_at ~ now), so the
    # two orders can differ: document_date puts Latte Lane first, name puts
    # Alpha first.
    imports(:receipt_understood).update!(
      extracted_data: imports(:receipt_understood).extracted_data.merge("date" => 1.day.from_now.to_date.iso8601)
    )

    get documents_path(q: { sort: "document_date" })
    assert_operator response.body.index("Latte Lane"), :<, response.body.index("Alpha receipt")

    get documents_path(q: { sort: "name" })
    assert_operator response.body.index("Alpha receipt"), :<, response.body.index("Latte Lane")
  end

  test "date range filters on the derived document date" do
    document_links(:unlinked_receipt).update!(title: "Dated receipt")
    document_links(:unlinked_receipt).receipt_imports.destroy_all
    document_links(:unlinked_receipt).update_columns(created_at: Time.zone.parse("2026-09-15 12:00"))

    get documents_path(q: { date_from: "2026-09-01", date_to: "2026-09-30" })
    assert_match "Dated receipt", response.body

    get documents_path(q: { date_from: "2026-10-01" })
    assert_no_match "Dated receipt", response.body
  end

  test "the displayed date is the same coerced date the range filter uses" do
    # (Ruling M8-C3, 2026-10-11 close-out) a needs_understanding draft carrying
    # a purchase date must not move the row's display: the range/sort SQL only
    # reads UNDERSTOOD drafts, and the displayed date must BE that authority.
    link = document_links(:unlinked_receipt)
    link.receipt_imports.destroy_all
    link.update!(title: "Undated review receipt")
    link.update_columns(created_at: Time.zone.parse("2026-09-15 12:00"))
    ReceiptImport.create!(family: families(:dylan_family), document_link: link, type: "ReceiptImport",
                          status: "pending", understanding_state: "needs_understanding",
                          extracted_data: { "date" => "2026-01-05" })
    date_format = families(:dylan_family).date_format

    get documents_path(q: { date_from: "2026-09-01", date_to: "2026-09-30" })

    assert_match "Undated review receipt", response.body # the range agrees: created_at is the authority
    assert_match Date.iso8601("2026-09-15").strftime(date_format), response.body
    assert_no_match Date.iso8601("2026-01-05").strftime(date_format), response.body
  end

  # -- the tag facet (M8 Task 6) ----------------------------------------------

  test "the tag facet filters by the stored snapshot" do
    document_links(:unlinked_receipt).update!(tags: %w[ohmzbudget receipt])
    document_links(:held_bill).update!(tags: %w[ohmzbudget bill])

    get documents_path(q: { tags: %w[bill] })
    assert_response :success
    assert_no_match document_links(:unlinked_receipt).title.to_s, response.body
    assert_match document_links(:held_bill).title.to_s, response.body
    assert_select "input[name='q[tags][]'][checked='checked'][value='bill']" # the active choice stays checked
  end

  # The facet is only usable if its choices reach the form — the pinned
  # controller -> component -> filter_form relay (M8 Task 6, the plan's
  # `tag_choices` flow; its Files list did not name the two index views).
  test "the tag facet renders the stored snapshot names as choices" do
    document_links(:held_bill).update!(tags: %w[ohmzbudget bill])

    get documents_path
    assert_select "input[name='q[tags][]'][value='bill']"
    assert_select "input[name='q[tags][]'][value='ohmzbudget']"
    assert_select "input[name='q[tags][]'][checked='checked'][value='bill']", count: 0
  end

  test "the tag facet states honestly when no tags are stored yet" do
    get documents_path
    assert_select "input[name='q[tags][]']", count: 0
    # (verifier-F4 discipline) fail on the missing key, not on a matching
    # "Translation missing: …" on both sides.
    assert I18n.exists?("document_browser.filters.no_tags")
    assert_match I18n.t("document_browser.filters.no_tags"), response.body
  end

  # -- the merchant / amount facet (M8 Task 7) --------------------------------

  test "the browser renders the merchant/amount facet fields for documents only" do
    get documents_path
    assert_select "input[name='q[merchant]']"
    assert_select "input[name='q[amount_min]']"
    assert_select "input[name='q[amount_max]']"
    # The statements note belongs to the other family: documents DO offer the
    # amount fields, so the degradation line must not appear here.
    assert I18n.exists?("document_browser.filters.statements_amount_note")
    assert_no_match I18n.t("document_browser.filters.statements_amount_note"), response.body
  end

  test "the merchant and amount facets narrow the list end to end" do
    # The understood draft's fixture extracted data (payee "Starbucks", total
    # "12.00") drives both predicates — and both render on the row.
    get documents_path(q: { merchant: "starb" })
    assert_match document_links(:understood_receipt_link).title.to_s, response.body
    assert_match "Starbucks", response.body
    assert_match imports(:receipt_understood).total_amount.to_s("F"), response.body
    assert_no_match document_links(:held_bill).title.to_s, response.body

    get documents_path(q: { amount_min: "10", amount_max: "15" })
    assert_match document_links(:understood_receipt_link).title.to_s, response.body
    assert_no_match document_links(:held_bill).title.to_s, response.body
  end

  # -- the sidebar ready-to-review count (M8 Task 9, Ruling M8-L1 decision 3) --

  test "the main nav badges Receipts & Bills with its ready-to-review count" do
    # Fixtures: receipt_understood's draft is understood (ready); receipt_draft
    # is awaiting_ocr (still reading) — so the family's count is exactly one.
    get documents_path
    assert_response :success
    assert_select "a[href='#{documents_path}'] [data-nav-badge]", text: "1"

    # It rides the nav on every page, like the insights badge.
    get root_path
    assert_select "a[href='#{documents_path}'] [data-nav-badge]", text: "1"

    # A reviewed-and-published receipt stops counting (else the badge would
    # inflate forever on a family's history).
    imports(:receipt_understood).update!(status: "complete")
    get documents_path
    assert_select "[data-nav-badge]", count: 0
  end

  test "the nav badge renders nothing when no document is ready to review" do
    sign_in users(:empty) # a family with no documents at all
    get documents_path
    assert_response :success
    assert_select "[data-nav-badge]", count: 0
  end

  # -- the status facet (M8 Task 9, Ruling M8-L2) ------------------------------

  test "the status facet renders over DocumentLink::STATUSES and narrows the list" do
    get documents_path
    DocumentLink::STATUSES.each do |status|
      assert_select "input[name='q[status][]'][value='#{status}']"
    end

    get documents_path(q: { status: %w[queued] })
    assert_response :success
    assert_match document_links(:held_bill).title.to_s, response.body
    assert_no_match document_links(:linked_receipt).title.to_s, response.body
    assert_select "input[name='q[status][]'][checked='checked'][value='queued']"

    # An unknown token filters nothing instead of widening (the source facet's
    # rule, mirrored).
    get documents_path(q: { status: %w[bogus] })
    assert_match document_links(:linked_receipt).title.to_s, response.body
  end
end
