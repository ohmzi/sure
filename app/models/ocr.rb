# frozen_string_literal: true

# The OCR sidecar. It reads exactly the photographed and scanned pages this
# feature exists for, running PaddleOCR behind one small HTTP contract
# (Ocr::Client documents it), so the engine is swappable without the app
# noticing.
module Ocr
  ENV_URL = "OCR_SERVICE_URL".freeze
  DEFAULT_URL = "http://ocr:9000".freeze

  def self.client = Client.new
  def self.configured? = client.configured?

  def self.url
    ENV[ENV_URL].presence || DEFAULT_URL
  end
end
