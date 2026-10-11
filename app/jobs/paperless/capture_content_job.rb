# frozen_string_literal: true

# Snapshots a settled document's OCR text into document_links.extracted_text.
# This is the ONLY reader of Paperless::Document#content outside M1/M2/M3, and
# it runs once per link: the archives' OCR search must keep working when
# paperless is down or its token is invalid (M7 locked decision 8), so nothing
# on a request path may depend on a live paperless call.
class Paperless::CaptureContentJob < ApplicationJob
  queue_as :default

  RETRY_WAIT = 30.seconds
  RETRY_ATTEMPTS = 3

  discard_on ActiveRecord::RecordNotFound

  retry_on Paperless::Error, wait: RETRY_WAIT, attempts: RETRY_ATTEMPTS, queue: :default

  def perform(document_link_id)
    link = DocumentLink.find(document_link_id)
    return if link.paperless_document_id.blank? || link.extracted_text.present?

    document = Paperless.client.document(link.paperless_document_id)
    link.record_content!(document.content)
  rescue Paperless::Error => e
    # A 401 is a rotation event, not a retry loop (spec §8.6): note it and give
    # up. Every other error is retried a bounded number of times; the row keeps
    # working (title/filename search) with no snapshot.
    raise e unless e.code == :unauthorized

    Paperless.note_token_invalid!
  end
end
