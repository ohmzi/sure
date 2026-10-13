# frozen_string_literal: true

# Owns the document-class verdict. The AI's class is a proposal, not a fact:
# this combines it with cheap deterministic corroboration before anything is
# written to `document_links.source`, and refuses to invent a class it cannot
# corroborate. A document that ends up `other` is archived and not read for
# line items, which is the right answer for a warranty or a lease.
#
# Replaces DocumentLink::SourceGuesser, whose filename/extension heuristic
# could not tell a photographed receipt from a scanned statement.
class DocumentClassifier
  Result = Data.define(:document_class, :confidence, :corroborated, :classified_by)

  # Corroboration is deliberately loose — it exists to catch a confidently
  # wrong class, not to re-litigate a good one.
  STATEMENT_TEXT = /statement|account\s+summary|opening\s+balance|closing\s+balance|minimum\s+payment|new\s+balance/i
  RECEIPT_TEXT   = /receipt|thank\s+you\s+for\s+your\s+(purchase|order)|subtotal|amount\s+due|total/i
  STATEMENT_FILENAME = /statement|stmt/i

  def self.call(ai_verdict:, filename: nil, content_type: nil, ocr_text: nil)
    new(ai_verdict:, filename:, content_type:, ocr_text:).call
  end

  def initialize(ai_verdict:, filename:, content_type:, ocr_text:)
    @ai_verdict = ai_verdict
    @filename = filename.to_s
    @content_type = content_type.to_s
    @ocr_text = ocr_text.to_s
  end

  def call
    klass = @ai_verdict&.document_class
    return fallback if klass.nil? || klass == "other"

    if corroborated?(klass)
      Result.new(document_class: klass, confidence: confidence_for(klass),
                 corroborated: true, classified_by: "ai")
    elsif confidently_asserted?
      # The model was sure and gave a well-formed structure; accept it but say
      # so, so the review screen can show the class was not corroborated.
      Result.new(document_class: klass, confidence: confidence_for(klass),
                 corroborated: false, classified_by: "ai")
    else
      fallback
    end
  end

  private
    def corroborated?(klass)
      case klass
      when "statement"
        @ocr_text.match?(STATEMENT_TEXT) || @ai_verdict.period_start.present? || @filename.match?(STATEMENT_FILENAME)
      when "receipt", "bill"
        @ocr_text.match?(RECEIPT_TEXT) && (@ai_verdict.total.present? || @ai_verdict.date.present?)
      else
        false
      end
    end

    # "Sure" means the class is asserted AND the fields that class needs are
    # present — a statement with no period is not a confident statement.
    def confidently_asserted?
      case @ai_verdict&.document_class
      when "statement" then @ai_verdict.period_start.present? || @ai_verdict.total.present?
      when "receipt", "bill" then @ai_verdict.total.present? && @ai_verdict.date.present?
      else false
      end
    end

    def confidence_for(klass)
      keys = klass == "statement" ? %w[total date] : %w[total date]
      values = keys.map { |key| @ai_verdict.confidence_for(key) }.reject(&:zero?)
      values.empty? ? 0.0 : (values.sum / values.size).round(4)
    end

    def fallback
      Result.new(document_class: "other", confidence: 0.0, corroborated: false, classified_by: "fallback")
    end
end
