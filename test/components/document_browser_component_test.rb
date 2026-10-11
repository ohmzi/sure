require "test_helper"

class DocumentBrowserComponentTest < ViewComponent::TestCase
  setup do
    @routes = Rails.application.routes.url_helpers
    @rows = [ DocumentBrowser::Row.for_document_link(document_links(:unlinked_receipt)) ]
  end

  test "renders the shared browser skeleton with a row, thumbnail and status" do
    render_inline(component(rows: @rows))

    assert_selector "#document-browser"
    assert_selector "form[method='get']"
    assert_selector "img[src='#{@routes.file_document_path(document_links(:unlinked_receipt), kind: "thumb")}']"
    assert_text I18n.t("documents.status.unlinked")
    assert_text I18n.t("documents.source.receipt")
  end

  test "renders the nothing-yet empty state without filters and the no-match state with them" do
    render_inline(component(rows: [], pagy: Pagy.new(count: 0)))
    assert_text I18n.t("document_browser.empty.documents_title")

    render_inline(component(rows: [], pagy: Pagy.new(count: 0), filters: { search: "nope" }))
    assert_text I18n.t("document_browser.empty.title")
    assert_selector "a[href='#{@routes.documents_path}']"
  end

  test "renders the statements family through the same skeleton" do
    statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family), account: accounts(:depository),
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )
    row = DocumentBrowser::Row.for_account_statement(statement)

    render_inline(component(family: :statements, title: "Statements", rows: [ row ], url: @routes.account_statements_path))

    assert_selector "#document-browser"
    assert_text statement.filename
    assert_no_selector "input[name='source[]']" # the statements family has no source facet
  end

  test "statements rows carry the type label and the extraction badge for the visible states" do
    statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family), account: accounts(:depository),
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )

    row = DocumentBrowser::Row.for_account_statement(statement)
    # The type label renders on every statements row; a missing key must not
    # hide behind Rails' silent "Translation missing:" fallback (verifier-F4
    # discipline — the same reason Task 2 pinned its draft-affordance keys).
    assert_equal I18n.t("account_statements.type.statement"), row.doc_type_label
    assert_equal [ I18n.t("account_statements.status.linked") ], row.statuses.map(&:label)

    %w[processing needs_template extraction_failed].each do |state|
      statement.update!(extraction_state: state)
      labels = DocumentBrowser::Row.for_account_statement(statement).statuses.map(&:label)

      assert_includes labels, I18n.t("document_browser.row.extraction.#{state}"),
                      "the #{state} extraction badge must carry its translated label"
    end

    statement.update!(extraction_state: :extracted)
    assert_equal [ I18n.t("account_statements.status.linked") ],
                 DocumentBrowser::Row.for_account_statement(statement).statuses.map(&:label)
  end

  private
    def component(family: :documents, title: "Receipts & Bills", rows: @rows, filters: {}, url: @routes.documents_path, **opts)
      DocumentBrowserComponent.new(
        family: family, title: title, url: url, rows: rows,
        pagy: Pagy.new(count: rows.size, page: 1), filters: filters,
        source_filter: DocumentLinksController::DEFAULT_SOURCES, **opts
      )
    end
end
