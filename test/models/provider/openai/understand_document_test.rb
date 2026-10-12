require "test_helper"

class Provider::Openai::UnderstandDocumentTest < ActiveSupport::TestCase
  # A custom uri_base forces the generic (chat-completions) path — exactly the
  # path DeepSeek and Ollama take.
  def provider
    Provider::Openai.new("test-key", uri_base: "https://api.deepseek.com/v1", model: "deepseek-flash")
  end

  test "understand_document returns a DocumentUnderstanding from the tool-free JSON reply" do
    stub_openai_chat(body: { "choices" => [ { "message" => { "content" => {
      "document_class" => "receipt", "total" => "9.99", "date" => "2026-10-01",
      "payee" => "Corner Shop", "line_items" => [], "field_confidence" => {}
    }.to_json } } ] })

    response = provider.understand_document(pages: [ "aW1n" ], ocr_text: "TOTAL 9.99", family: families(:dylan_family))

    assert response.success?, response.error&.message
    assert_equal "receipt", response.data.document_class
    assert_equal BigDecimal("9.99"), response.data.total
  end

  test "an unparseable reply is a provider error, not an exception escaping" do
    stub_openai_chat(body: { "choices" => [ { "message" => { "content" => "I cannot read this." } } ] })

    response = provider.understand_document(pages: [ "aW1n" ], ocr_text: "", family: families(:dylan_family))

    assert_not response.success?
  end
end
