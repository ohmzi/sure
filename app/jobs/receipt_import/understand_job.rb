# frozen_string_literal: true

# Turns a settled receipt draft's OCR snapshot into `extracted_data` and item
# rows. Reads document_links.extracted_text ONLY — the snapshot job is the one
# paperless reader (M7 decision 8), so this path works when paperless is down.
# Never writes money (D8); publishing is the user's reviewed decision (Task 7).
class ReceiptImport::UnderstandJob < ApplicationJob
  queue_as :default

  # The draft/snapshot race: the wizard creates the draft while the upload is
  # still in flight. Wait for the snapshot a bounded number of times (Task 1's
  # capture job is what delivers it), then degrade to manual entry rather than
  # hanging on "Reading…".
  WaitingForText = Class.new(StandardError)
  WAIT_FOR_TEXT = 10.seconds
  MAX_WAITS = 18

  discard_on ActiveRecord::RecordNotFound

  retry_on WaitingForText, wait: WAIT_FOR_TEXT, attempts: MAX_WAITS do |job, _error|
    ReceiptImport.find_by(id: job.arguments.first)
                &.mark_needs_understanding!("no OCR text arrived after #{WAIT_FOR_TEXT.inspect} x #{MAX_WAITS}")
  end

  def perform(receipt_import_id)
    draft = ReceiptImport.find(receipt_import_id)
    return if draft.understood?

    link = draft.document_link
    if link.nil?
      return draft.mark_needs_understanding!("the document link is gone")
    end

    if link.extracted_text.present?
      draft.apply_extraction!(ReceiptImport::Extractor.call(link.extracted_text))
    elsif link.status.in?(%w[queued processing])
      raise WaitingForText
    else
      draft.mark_needs_understanding!("no OCR text for a #{link.status} document")
    end
  end
end
