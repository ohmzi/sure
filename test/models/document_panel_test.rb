require "test_helper"

# The per-document "what I understood" view-model (spec §9): the read, its
# doubts, and what the document became. `understood_receipt_link` carries a
# succeeded extraction fixture; `queued_receipt` has no read at all (the state
# every document is in on a host with no provider configured).
class DocumentPanelTest < ActiveSupport::TestCase
  test "fields carry their confidence and read as unsure when the model was" do
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "openai", model: "deepseek-flash", ocr_engine: "paddleocr",
      page_count: 1, status: "succeeded", ocr_text: "ACME\nTOTAL 12.34",
      verdict: { "document_class" => "receipt", "total" => "12.34", "payee" => "Acme" },
      field_confidence: { "total" => 0.98, "payee" => 0.31 }
    )

    panel = DocumentPanel.new(link.reload)
    total = panel.fields.find { |f| f.label == "total" }
    payee = panel.fields.find { |f| f.label == "payee" }

    assert_equal "12.34", total.value
    assert_in_delta 0.98, total.confidence, 0.001
    assert_not total.unsure?, "a 0.98 confidence is not a doubt"
    assert payee.unsure?, "a 0.31 confidence must render as unsure, not as a plain value"
  end

  test "an unread document says why rather than showing an empty panel" do
    panel = DocumentPanel.new(document_links(:queued_receipt))

    assert_not panel.read?
    assert panel.empty_reason.present?
  end

  test "the unread reason is the link's own hold when there is one" do
    link = document_links(:queued_receipt)
    # The live host's exact state: no provider, so the read was held with its
    # reason on the link and no extraction row was ever written.
    link.update_columns(failure_message: "no AI provider is configured")

    panel = DocumentPanel.new(link)

    assert_equal "no AI provider is configured", panel.empty_reason
  end

  test "outcomes name what the document became" do
    panel = DocumentPanel.new(document_links(:understood_receipt_link))

    assert panel.outcomes.any? { |o| o.label.match?(/receipt|draft/i) }
  end

  test "the viewer splits only when there is a read worth showing" do
    assert_not DocumentPanel.new(document_links(:queued_receipt)).split?
    assert DocumentPanel.new(document_links(:understood_receipt_link)).split?
  end

  test "checks keep the three states apart: pass, not checkable, fail" do
    panel = DocumentPanel.new(document_links(:understood_receipt_link))
    by_label = panel.checks.index_by(&:label)

    assert_equal true, by_label.fetch("OCR and AI agree on the total").state
    assert_nil by_label.fetch("the line items add up to the total").state,
               "a check the pipeline could not run is not a pass"
    assert_equal false, by_label.fetch("the card or account number was found in the page text").state
  end

  test "a document read but with nothing to say does not split" do
    # A succeeded read whose verdict carried no field the panel knows: it is a
    # read, but it has nothing to say, so the viewer stays a picture.
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(document_link: link, provider: "openai", status: "succeeded",
                               verdict: {}, field_confidence: {})

    panel = DocumentPanel.new(link.reload)

    assert panel.read?, "a succeeded read is a read"
    assert_not panel.split?, "but with no fields there is nothing worth splitting the viewer for"
  end
end
