# frozen_string_literal: true

# A read's OCR result, kept on the staging volume beside the document's bytes
# so a retry with another reader does not run OCR — and the GPU — again. Kept
# while a document may still be retried; dropped with the document's bytes.
#
# Best-effort by design: the result carries 300-DPI page images, so a phone
# photo or a multi-page scan can be large, and a full disk is possible. A cache
# that cannot be written is simply not written — the read never fails for it,
# and a partial file is never left behind for a later read to trip over.
class DocumentLink::OcrCache
  MAX_BYTES = 200.megabytes

  def self.max_bytes = MAX_BYTES

  def self.write(link, result)
    payload = { engine: result.engine, pages: result.pages.map(&:to_h) }.to_json
    return false if payload.bytesize > max_bytes

    path = path_for(link)
    DocumentLink::Staging.root.mkpath
    partial = "#{path}.partial"
    File.open(partial, "wb") { |file| file.write(payload) }
    File.rename(partial, path)
    true
  rescue StandardError => e
    Rails.logger.warn("DocumentLink::OcrCache could not cache OCR for #{link.id}: #{e.class}")
    File.delete(partial) if partial && File.exist?(partial)
    false
  end

  def self.read(link)
    data = nil
    DocumentLink::Staging.open(path_for(link).to_s) { |file| data = JSON.parse(file.read) }
    return nil unless data

    pages = data.fetch("pages", []).map do |page|
      Ocr::Result::Page.new(number: page["number"], text: page["text"], confidence: page["confidence"],
                            boxes: page["boxes"], image: page["image"])
    end
    Ocr::Result.new(pages: pages, engine: data["engine"])
  rescue JSON::ParserError
    nil
  end

  def self.delete(link)
    DocumentLink::Staging.delete(path_for(link).to_s)
  end

  # Through Staging.resolve!, so the cache can never land outside the staging
  # root; the name is the link's uuid, never client input.
  def self.path_for(link) = DocumentLink::Staging.resolve!("#{link.id}.ocr.json")
  private_class_method :path_for
end
