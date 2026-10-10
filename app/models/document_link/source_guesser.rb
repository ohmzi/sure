# frozen_string_literal: true

# Best-effort receipt-vs-statement heuristic for a freshly uploaded file, with a
# one-tap override in the dropzone (spec §8.1). No local OCR exists, so this is
# filename-based; a text-layer heuristic is deferred to the M2 statement
# templates. Images are always receipts.
class DocumentLink::SourceGuesser
  STATEMENT_PATTERN = /\b(e-?statement|statement|account summary|bank statement|invoice)\b/i

  def self.guess(filename:, content_type:)
    return :receipt if content_type.to_s.start_with?("image/")
    return :statement if filename.to_s.match?(STATEMENT_PATTERN)
    :receipt
  end
end
