require "test_helper"

# The document hold panel's "unread" state is where the owner's live report
# landed (2026-10-13): the AI key fields had no findable home, so "Set up a
# provider" was a dead end in practice. The panel must now name that home and
# link straight to it, while keeping the manual-entry alternative. A stub panel
# keeps this a pure view test — the layout and every other state are elsewhere.
class DocumentsUnderstandingPanelViewTest < ActionView::TestCase
  # Minimal stand-in for DocumentPanel covering only the readers the unread
  # branch touches; read? is false so the branch under test is the one rendered.
  UnreadPanel = Struct.new(:reason, keyword_init: true) do
    def read? = false
    def reading? = false
    def empty_reason = reason
  end

  test "the unread panel names the provider's home and links to the AI provider anchor" do
    render partial: "documents/understanding",
           locals: { panel: UnreadPanel.new(reason: "No AI provider is configured.") }

    assert_includes rendered, I18n.t("documents.understanding.unread.set_up_provider")
    assert_includes rendered, I18n.t("documents.understanding.unread.provider_location")
    assert_includes rendered, I18n.t("documents.understanding.unread.enter_by_hand")
    # The affordance points at the settings page's AI provider section, named by
    # the `ai-provider` anchor the view adds.
    assert_select "a[href=?]", settings_hosting_path(anchor: "ai-provider")
    # ...and the manual path is still offered.
    assert_select "a[href=?]", new_transaction_path
  end
end
