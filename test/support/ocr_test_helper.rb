# frozen_string_literal: true

module OcrTestHelper
  # Stubs the sidecar's success shape. Any test that exercises the pipeline
  # calls this; a test that wants a specific failure stubs WebMock itself.
  def stub_ocr_success(pages:, engine: "paddleocr-3.0")
    body = {
      engine: engine,
      pages: pages.map do |p|
        entry = { page: p[:page], text: p[:text], confidence: p.fetch(:confidence, 0.95),
                  boxes: p.fetch(:boxes, []) }
        entry[:image] = p[:image] if p[:image]
        entry
      end
    }
    stub_request(:post, "#{Ocr.url}/ocr").to_return(status: 200, body: body.to_json,
                                                    headers: { "Content-Type" => "application/json" })
  end

  def stub_openai_chat(body:, status: 200)
    stub_request(:post, %r{/chat/completions\z}).to_return(
      status: status, headers: { "Content-Type" => "application/json" }, body: body.to_json
    )
  end

  # A provider double returning one understanding verdict, so the pipeline runs
  # end to end without HTTP. Mirrors DocumentUnderstandingJobTest::FakeProvider
  # (which the job's own tests use) and lets the system journeys exercise the
  # read without a live provider.
  class StubDocumentProvider
    attr_reader :provider_name, :llm_model
    Response = Struct.new(:success?, :data, :error)

    def initialize(verdict)
      @provider_name = "openai"
      @llm_model = "deepseek-flash"
      @response = Response.new(true, DocumentUnderstanding.new(verdict), nil)
    end

    def supports_document_understanding? = true
    def understand_document(pages:, ocr_text:, family: nil, model: "") = @response
  end

  # A receipt verdict whose institution/last4 hints resolve to an account the
  # system tests pin (see each file's setup).
  RECEIPT_READING = {
    "document_class" => "receipt", "institution_name" => "Chase",
    "total" => "4.75", "date" => "2026-09-14", "payee" => "Acme Store",
    "currency" => "USD", "card_last4" => "4242",
    "line_items" => [ { "description" => "Coffee", "amount" => "4.75" } ],
    "field_confidence" => { "total" => 0.98, "date" => 0.97 }
  }.freeze

  def stub_document_provider(verdict = RECEIPT_READING)
    Provider::Registry.stubs(:preferred_llm_provider).returns(StubDocumentProvider.new(verdict))
  end
end

class ActiveSupport::TestCase
  include OcrTestHelper
end
