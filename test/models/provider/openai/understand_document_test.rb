require "test_helper"

class Provider::Openai::UnderstandDocumentTest < ActiveSupport::TestCase
  # A custom uri_base forces the generic (chat-completions) path — exactly the
  # path DeepSeek and Ollama take.
  def provider
    Provider::Openai.new("test-key", uri_base: "https://api.deepseek.com/v1", model: "deepseek-flash")
  end

  # No uri_base takes the native Responses-API path (stock OpenAI).
  def native_provider
    Provider::Openai.new("test-key", model: "gpt-4.1")
  end

  def stub_openai_responses(body:, status: 200)
    stub_request(:post, %r{/responses\z}).to_return(
      status: status, headers: { "Content-Type" => "application/json" }, body: body.to_json
    )
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

  test "the generic (chat) request body carries the page images and the OCR text" do
    stub_openai_chat(body: { "choices" => [ { "message" => { "content" => { "document_class" => "receipt" }.to_json } } ] })

    provider.understand_document(pages: [ "aW1n" ], ocr_text: "TOTAL 9.99", family: families(:dylan_family))

    user_content = nil
    assert_requested(:post, %r{/chat/completions\z}) do |req|
      user_content = JSON.parse(req.body).dig("messages", 1, "content")
    end

    assert_equal "image_url", user_content[0]["type"]
    assert_equal "data:image/png;base64,aW1n", user_content[0].dig("image_url", "url")
    assert_equal "text", user_content[1]["type"]
    assert_includes user_content[1]["text"], "TOTAL 9.99"
  end

  # A configured response cap bounds how long a document read can generate —
  # a model that loops on a dense page cannot hold the GPU indefinitely.
  test "a configured response cap is sent with the document read" do
    Setting.stubs(:llm_max_response_tokens).returns(8192)
    stub_openai_chat(body: { "choices" => [ { "message" => { "content" => { "document_class" => "receipt" }.to_json } } ] })

    provider.understand_document(pages: [ "aW1n" ], ocr_text: "TOTAL 9.99", family: families(:dylan_family))

    assert_requested(:post, %r{/chat/completions\z}) { |req| JSON.parse(req.body)["max_tokens"] == 8192 }
  end

  test "with no cap configured none is sent, so a stock install is never truncated" do
    Setting.stubs(:llm_max_response_tokens).returns(nil)
    stub_openai_chat(body: { "choices" => [ { "message" => { "content" => { "document_class" => "receipt" }.to_json } } ] })

    with_env_overrides("LLM_MAX_RESPONSE_TOKENS" => nil) do
      provider.understand_document(pages: [ "aW1n" ], ocr_text: "TOTAL 9.99", family: families(:dylan_family))
    end

    assert_requested(:post, %r{/chat/completions\z}) { |req| !JSON.parse(req.body).key?("max_tokens") }
  end

  test "the native (responses) request body carries the page images and the OCR text" do
    stub_openai_responses(body: { "output" => [ { "type" => "message", "content" => [
      { "type" => "output_text", "text" => { "document_class" => "receipt" }.to_json }
    ] } ] })

    response = native_provider.understand_document(pages: [ "aW1n" ], ocr_text: "TOTAL 9.99", family: families(:dylan_family))
    assert response.success?, response.error&.message

    content = nil
    assert_requested(:post, %r{/responses\z}) do |req|
      content = JSON.parse(req.body).dig("input", 0, "content")
    end

    assert_equal "input_image", content[0]["type"]
    assert_equal "data:image/png;base64,aW1n", content[0]["image_url"]
    assert_equal "input_text", content[1]["type"]
    assert_includes content[1]["text"], "TOTAL 9.99"
  end
end
