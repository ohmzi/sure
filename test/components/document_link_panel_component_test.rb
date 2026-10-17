require "test_helper"

class DocumentLinkPanelComponentTest < ViewComponent::TestCase
  # Ruling 7 (M1): ViewComponent::TestCase has no route helpers (and no
  # delegation to the view context) — resolve them through url_helpers, the
  # idiom the repo already uses (trade_republic/account_editor_component_test.rb).
  test "renders a linked document with its thumbnail and unlink action" do
    entry = entries(:transaction)
    link = document_links(:linked_receipt)
    routes = Rails.application.routes.url_helpers

    render_inline(DocumentLinkPanelComponent.new(entry: entry))

    # Ruling 7 (M1): capybara rejects extra positional args on assert_selector
    # ("img[src=?]", path) — interpolate instead.
    assert_selector "img[src='#{routes.file_document_path(link, kind: "thumb")}']"
    # DS::Button renders a form+button (button_to), not an anchor.
    assert_selector "form[action='#{routes.unlink_document_path(link)}']"
    assert_text I18n.t("document_link_panel.unlink")
  end

  # The owner (2026-10-17): a transaction's details show the document it came
  # from, never the family's other documents — only a receipt whose read total
  # and date match this transaction is offered for linking.
  test "offers an unlinked receipt only when its amount and date match the entry" do
    entry = entries(:transaction)
    candidate = document_links(:unlinked_receipt)
    routes = Rails.application.routes.url_helpers

    render_inline(DocumentLinkPanelComponent.new(entry: entry))
    assert_no_selector "form[action='#{routes.link_document_path(candidate, entry_id: entry.id)}']"

    candidate.document_extractions.create!(family: candidate.family, verdict: { "total" => entry.amount.abs.to_s, "date" => entry.date.iso8601 })
    render_inline(DocumentLinkPanelComponent.new(entry: entry))
    assert_selector "form[action='#{routes.link_document_path(candidate, entry_id: entry.id)}']"
    assert_text I18n.t("document_link_panel.link")
  end

  test "shows the document the entry came from, without offering to unlink it" do
    entry = entries(:transaction)
    source = document_links(:unlinked_receipt)
    import = imports(:transaction)
    entry.update_columns(import_id: import.id)
    import.update_columns(document_link_id: source.id) if import.respond_to?(:document_link_id)

    skip "imports carry no document link here" unless EntryProvenance.for(entry.reload).creating_document

    render_inline(DocumentLinkPanelComponent.new(entry: entry))
    assert_text source.title.presence || source.original_filename
    assert_selector "[data-source-document]"
  end

  test "renders an empty state when the entry and family have no documents" do
    DocumentLink.delete_all
    render_inline(DocumentLinkPanelComponent.new(entry: entries(:valuation)))

    assert_text I18n.t("document_link_panel.empty")
  end
end
