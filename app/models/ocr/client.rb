# frozen_string_literal: true

# Faraday client for the OCR sidecar, following the Provider/Faraday idiom the
# rest of the app uses: one connection, a bounded timeout, and typed errors —
# never a bare raise that the caller cannot classify.
class Ocr::Client
  REQUEST_TIMEOUT = 120  # a 40-page statement is minutes on CPU, seconds on GPU

  def initialize(url: Ocr.url)
    @url = url
  end

  def configured? = @url.present?

  def recognize(io:, filename:, content_type:, include_images: false)
    raise Ocr::Error.new(:not_configured) unless configured?

    response = connection.post("#{@url}/ocr") do |req|
      req.body = {
        file: Faraday::Multipart::FilePart.new(io, content_type, filename),
        include_images: include_images ? "true" : "false"
      }
    end

    return Ocr::Result.failure(:unreadable) if response.status == 422

    unless response.success?
      raise Ocr::Error.new(:server_error, "OCR sidecar returned #{response.status}")
    end

    parse(response.body)
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
    raise Ocr::Error.new(:unreachable, e.message)
  rescue JSON::ParserError => e
    raise Ocr::Error.new(:bad_response, e.message)
  end

  private
    def parse(body)
      payload = body.is_a?(String) ? JSON.parse(body) : body
      pages = Array(payload["pages"]).map do |page|
        Ocr::Result::Page.new(
          number: page["page"].to_i,
          text: page["text"].to_s,
          confidence: page["confidence"].to_f,
          boxes: Array(page["boxes"]),
          image: page["image"]
        )
      end
      Ocr::Result.new(pages: pages, engine: payload["engine"])
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.request :multipart
        f.options.timeout = REQUEST_TIMEOUT
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end
end
