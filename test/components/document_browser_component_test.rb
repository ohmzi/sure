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

  private
    def component(family: :documents, title: "Receipts & Bills", rows: @rows, filters: {}, url: @routes.documents_path, **opts)
      DocumentBrowserComponent.new(
        family: family, title: title, url: url, rows: rows,
        pagy: Pagy.new(count: rows.size, page: 1), filters: filters,
        source_filter: DocumentLinksController::DEFAULT_SOURCES, **opts
      )
    end
end
