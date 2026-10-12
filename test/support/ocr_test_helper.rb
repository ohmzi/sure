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
end

class ActiveSupport::TestCase
  include OcrTestHelper
end
