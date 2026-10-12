# frozen_string_literal: true

# The native read: one idempotent job per document.
#
# paperless did this in two halves — Upload/TaskPoll/CaptureContent for the text,
# StatementOcrJob or ReceiptImport::UnderstandJob for the meaning. Both halves
# are one job now, because both halves need the same thing: the pages.
class DocumentUnderstandingJob < ApplicationJob
  queue_as :heavy

  # An OCR failure is transient far more often than it is terminal — the sidecar
  # is restarting, the GPU is busy, the weights are still loading. Retry with
  # backoff; only a service that ANSWERED and said "unreadable" lands terminally.
  retry_on Ocr::Error, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  UNREADABLE_MESSAGE = "the OCR engine found no text in this document".freeze
  NO_PROVIDER_MESSAGE = "no AI provider is configured".freeze

  # The deterministic cross-checks. Pure, so the review screen can call them and
  # so they are testable without a provider or a sidecar.
  def self.validate(understanding, ocr_text:)
    ai_total = understanding.total
    ocr_total = OcrTotal.call(ocr_text)

    line_items = understanding.line_items.map { |i| BigDecimal(i["amount"].to_s.delete(",")) rescue nil }
    sum_ok =
      if understanding.line_items.empty? || ai_total.nil?
        nil # nothing to check — not a pass, not a fail
      else
        line_items.compact.sum == ai_total
      end

    last4 = [ understanding.account_last4, understanding.card_last4 ].compact
    {
      "totals_agree" => (ai_total.present? && ocr_total.present? ? ai_total == ocr_total : nil),
      "ai_total" => ai_total&.to_s("F"),
      "ocr_total" => ocr_total&.to_s("F"),
      "line_items_sum" => sum_ok,
      "last4_in_ocr" => last4.empty? ? nil : last4.any? { |digits| ocr_text.to_s.include?(digits) },
      "date_parses" => understanding.date.present?
    }
  end

  def perform(document_link_id)
    link = DocumentLink.find(document_link_id)

    # Idempotent: a re-delivery, or the reaper re-enqueueing, must be a no-op
    # once the read settled. `processing` is allowed so a crashed attempt resumes.
    return unless link.status.in?(%w[queued processing])

    link.mark_processing!

    return link.hold!(message: "no OCR service is configured") unless Ocr.configured?

    result = read(link)
    return land_unreadable(link, result.failure_code) if result.failure?
    # A 200 that carried no text (Task 3's client reads a body with no `pages`
    # key as a non-failure, empty result) is still "nothing was understood":
    # hold the row for the user, never settle a text-less read and never hand an
    # empty read to the paid model.
    return land_unreadable(link, :no_text) if result.text.blank?

    link.record_content!(result.text, refresh: true)

    provider = Provider::Registry.preferred_llm_provider
    return link.hold!(message: NO_PROVIDER_MESSAGE) unless provider&.supports_document_understanding?

    response = provider.understand_document(pages: result.page_images, ocr_text: result.text, family: link.family)
    return link.hold!(message: "AI provider failed: #{response.error&.message}") unless response.success?

    understanding = response.data
    validations = self.class.validate(understanding, ocr_text: result.text)
    classification = DocumentClassifier.call(
      ai_verdict: understanding, filename: link.original_filename,
      content_type: link.content_type, ocr_text: result.text
    )

    DocumentExtraction.record!(
      document_link: link,
      provider: provider.provider_name,
      model: provider.llm_model,
      ocr_engine: result.engine,
      page_count: result.pages.size,
      ocr_text: result.text.first(DocumentLink::EXTRACTED_TEXT_LIMIT),
      raw_response: understanding.to_verdict,
      verdict: understanding.to_verdict,
      field_confidence: understanding.field_confidence.to_h,
      validations: validations,
      status: "succeeded"
    )

    link.update!(page_count: result.pages.size, ocr_engine: result.engine,
                 ocr_finished_at: Time.current)
    link.classify!(document_class: classification.document_class,
                   confidence: classification.confidence,
                   classified_by: classification.classified_by)
    link.settle!
    link.broadcast_row_update!
  rescue Ocr::Error
    # Transient: let retry_on do its work. The row stays `processing`.
    raise
  rescue => e
    # Anything else is ours: record it on the link so the archive can show it,
    # and leave the row retryable rather than wedged.
    DocumentLink.find_by(id: document_link_id)&.hold!(message: "read failed: #{e.class}: #{e.message}")
    raise
  end

  private
    def read(link)
      link.stored_io do |io|
        return Ocr.client.recognize(io: io, filename: link.original_filename.to_s,
                                    content_type: link.content_type.presence || "application/octet-stream",
                                    include_images: true)
      end
      # stored_io returns nil when the column is blank — a row with no bytes can
      # never settle, so fail it loudly instead of looping.
      raise "document has no stored bytes"
    end

    def land_unreadable(link, code)
      link.hold!(message: "#{UNREADABLE_MESSAGE} (#{code})")
    end
end
