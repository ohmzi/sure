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

  # Minimal stand-in for the read branch: the field list is the only thing under
  # test, so the other readers return empty.
  class ReadPanel
    def initialize(fields:) = @fields = fields

    def read? = true
    def reading? = false
    def document_class = "receipt"
    def classification_confidence = 0.9
    def account = nil
    def fields = @fields
    def checks = []
    def outcomes = []
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

  # W8-G: the class row is hidden by the field's verdict KEY, not by its label.
  # The labels here are deliberately unlike the keys — the shape a translation
  # takes — so a label-based filter or a label-based `data-field` fails this: the
  # class row would reappear, and the field selectors would stop matching.
  test "the class row is filtered by the field's key, and data-field carries the key, not the label" do
    fields = [
      DocumentPanel::Field.new(key: "document_class", label: "Document type", value: "receipt", confidence: nil),
      DocumentPanel::Field.new(key: "total", label: "Amount due", value: "12.34", confidence: 0.98)
    ]

    render partial: "documents/understanding", locals: { panel: ReadPanel.new(fields: fields) }

    # Hidden by key: the class row's (translated) label never renders.
    assert_not_includes rendered, "Document type"
    assert_select "[data-field='document_class']", false
    # Every other field is selectable by its stable key, and still shows its label.
    assert_select "[data-field='total']"
    assert_includes rendered, "Amount due"
    assert_includes rendered, "12.34"
  end
end
