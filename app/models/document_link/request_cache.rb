# frozen_string_literal: true

# Per-request memo for the derived PDF data the viewer reads (P1.12). The
# expensive pieces — the text layer and pdfinfo's page count — are read once
# per document and request, then dropped: nothing here outlives the request.
class DocumentLink::RequestCache < ActiveSupport::CurrentAttributes
  attribute :reads

  # Yields at most once per key in this request and memoizes the value.
  def self.fetch(key)
    self.reads ||= {}
    return reads[key] if reads.key?(key)

    reads[key] = yield
  end
end
