# frozen_string_literal: true

# A read's OCR result, kept on the staging volume beside the document's bytes
# so a retry with another reader does not run OCR — and the GPU — again. Kept
# while a document may still be retried; dropped with the document's bytes.
class DocumentLink::OcrCache
  def self.write(link, result)
    payload = {
      engine: result.engine,
      pages: result.pages.map { |page| page.to_h }
    }
    DocumentLink::Staging.write(io: StringIO.new(payload.to_json), id: key(link))
  end

  def self.read(link)
    data = nil
    DocumentLink::Staging.open(DocumentLink::Staging.root.join(key(link)).to_s) { |file| data = JSON.parse(file.read) }
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
    DocumentLink::Staging.delete(DocumentLink::Staging.root.join(key(link)).to_s)
  end

  def self.key(link) = "#{link.id}.ocr.json"
  private_class_method :key
end
