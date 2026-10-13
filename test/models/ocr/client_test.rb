require "test_helper"

class Ocr::ClientTest < ActiveSupport::TestCase
  setup do
    @client = Ocr::Client.new(url: "http://ocr:9000")
  end

  test "recognize parses pages, joins the text and averages the confidence" do
    stub_ocr_success(pages: [
      { page: 1, text: "ACME STORE", confidence: 0.9 },
      { page: 2, text: "TOTAL 12.34", confidence: 1.0 }
    ])

    result = @client.recognize(io: StringIO.new("bytes"), filename: "r.png", content_type: "image/png")

    assert_equal 2, result.pages.size
    assert_equal "ACME STORE\n\nTOTAL 12.34", result.text
    assert_in_delta 0.95, result.confidence, 0.001
    assert_equal 2, result.pages.last.number
    assert_empty result.page_images, "images are opt-in; the text-only caller must not pay for them"
  end

  test "include_images returns the rendered page images" do
    stub_ocr_success(pages: [
      { page: 1, text: "ACME STORE", confidence: 0.9, image: "iVBORw0KGgo=" },
      { page: 2, text: "TOTAL 12.34", confidence: 1.0, image: "iVBORw0KGg1=" }
    ])

    result = @client.recognize(io: StringIO.new("bytes"), filename: "s.pdf",
                               content_type: "application/pdf", include_images: true)

    assert_equal %w[iVBORw0KGgo= iVBORw0KGg1=], result.page_images
  end

  test "an unreachable service raises Ocr::Error(:unreachable)" do
    stub_request(:post, "http://ocr:9000/ocr").to_raise(Faraday::ConnectionFailed.new("refused"))

    error = assert_raises(Ocr::Error) do
      @client.recognize(io: StringIO.new("b"), filename: "r.png", content_type: "image/png")
    end
    assert_equal :unreachable, error.code
  end

  test "a 5xx from the sidecar raises Ocr::Error(:server_error)" do
    stub_request(:post, "http://ocr:9000/ocr").to_return(status: 503, body: "busy")

    error = assert_raises(Ocr::Error) do
      @client.recognize(io: StringIO.new("b"), filename: "r.png", content_type: "image/png")
    end
    assert_equal :server_error, error.code
  end

  test "a body that is not JSON raises Ocr::Error(:bad_response)" do
    stub_request(:post, "http://ocr:9000/ocr").to_return(status: 200, body: "not json",
                                                         headers: { "Content-Type" => "application/json" })

    error = assert_raises(Ocr::Error) do
      @client.recognize(io: StringIO.new("b"), filename: "r.png", content_type: "image/png")
    end
    assert_equal :bad_response, error.code
  end

  test "an unconfigured client raises Ocr::Error(:not_configured) before any request" do
    # No HTTP stub is set for this URL, so a request would raise WebMock's
    # NetConnectNotAllowedError instead — the guarded Ocr::Error proves the client
    # never reached the wire.
    client = Ocr::Client.new(url: nil)

    error = assert_raises(Ocr::Error) do
      client.recognize(io: StringIO.new("b"), filename: "r.png", content_type: "image/png")
    end
    assert_equal :not_configured, error.code
  end

  test "an unreadable document surfaces the 422 rather than raising" do
    stub_request(:post, "http://ocr:9000/ocr").to_return(status: 422, body: { error: "unreadable" }.to_json)

    result = @client.recognize(io: StringIO.new("b"), filename: "r.png", content_type: "image/png")

    assert result.failure?
    assert_equal :unreadable, result.failure_code
  end

  test "configured? is false without a URL" do
    assert_not Ocr::Client.new(url: nil).configured?
    assert @client.configured?
  end
end
