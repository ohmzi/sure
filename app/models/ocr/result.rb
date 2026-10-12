# frozen_string_literal: true

# What the OCR read. `failure?` is a first-class outcome, not an exception: an
# unreadable photo is a normal thing to upload, and Task 7 must be able to see
# it and land the document as needs_understanding rather than crash.
class Ocr::Result
  Page = Data.define(:number, :text, :confidence, :boxes, :image)

  attr_reader :pages, :engine, :failure_code

  def self.failure(code)
    new(pages: [], engine: nil, failure_code: code)
  end

  def initialize(pages:, engine: nil, failure_code: nil)
    @pages = pages
    @engine = engine
    @failure_code = failure_code
  end

  def failure? = @failure_code.present?

  def text
    pages.map(&:text).reject(&:blank?).join("\n\n")
  end

  # The rendered page images (base64 PNG). Only populated when the caller passed
  # include_images — the vision call needs them, a text-only consumer does not.
  def page_images = pages.filter_map(&:image)

  def confidence
    return 0.0 if pages.empty?

    pages.sum(&:confidence) / pages.size
  end
end
