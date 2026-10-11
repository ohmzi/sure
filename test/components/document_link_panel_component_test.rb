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

  test "offers an unlinked document to link to the entry" do
    entry = entries(:transaction)
    candidate = document_links(:unlinked_receipt)
    routes = Rails.application.routes.url_helpers

    render_inline(DocumentLinkPanelComponent.new(entry: entry))

    assert_selector "form[action='#{routes.link_document_path(candidate, entry_id: entry.id)}']"
    assert_text I18n.t("document_link_panel.link")
  end

  test "renders an empty state when the entry and family have no documents" do
    DocumentLink.delete_all
    render_inline(DocumentLinkPanelComponent.new(entry: entries(:valuation)))

    assert_text I18n.t("document_link_panel.empty")
  end
end
