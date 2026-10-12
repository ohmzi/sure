# frozen_string_literal: true

# The independent witness for the model's total.
#
# This is the ONE piece of the deleted deterministic receipt parser that
# survives, and it survives for a single reason: auto-posting a receipt (spec
# N6) requires the OCR read and the vision read to AGREE on the total, and
# agreement needs two independent reads. There is deliberately no "largest money
# token" fallback — a wrong value here cannot create money (this method writes
# nothing), but it could wrongly suppress a correct auto-post, so it errs toward
# nil.
class OcrTotal
  LABELLED = /\b(?:grand\s+total|amount\s+due|balance\s+due|total)\b[^\d$\n]{0,20}\$?\s*(\d[\d,]*\.\d{2})/i
  GRAND = /\b(?:grand\s+total|amount\s+due|balance\s+due)\b[^\d$\n]{0,20}\$?\s*(\d[\d,]*\.\d{2})/i

  def self.call(text)
    new(text.to_s).call
  end

  def initialize(text)
    @text = text
  end

  def call
    match = @text.match(GRAND) || @text.match(LABELLED)
    return nil unless match

    BigDecimal(match[1].delete(","))
  rescue ArgumentError
    nil
  end
end
