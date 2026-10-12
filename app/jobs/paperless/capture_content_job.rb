# frozen_string_literal: true

# Snapshots a settled document's OCR text and paperless tags into
# document_links (M8 locked decision 6). This is the ONLY reader of
# Paperless::Document#content outside M1/M2/M3, and it runs once per link: the
# archives' OCR search and tag facet must keep working when paperless is down or
# its token is invalid (M7 locked decision 8), so nothing on a request path may
# depend on a live paperless call.
class Paperless::CaptureContentJob < ApplicationJob
  queue_as :default

  RETRY_WAIT = 30.seconds
  RETRY_ATTEMPTS = 3

  discard_on ActiveRecord::RecordNotFound

  retry_on Paperless::Error, wait: RETRY_WAIT, attempts: RETRY_ATTEMPTS, queue: :default

  def perform(document_link_id)
    link = DocumentLink.find(document_link_id)
    return if link.paperless_document_id.blank?
    return if link.extracted_text.present? && link.tags.present?

    client = Paperless.client
    document = client.document(link.paperless_document_id)
    if link.record_content!(document.content)
      # The other side of the draft/snapshot race (M7 Task 6): a receipt draft
      # committed before this snapshot landed cannot see the text by polling,
      # so kick its understanding now. A draft created after the snapshot was
      # written is kicked by ReceiptImport.create_from_document_link! instead.
      link.receipt_imports.find_each { |draft| ReceiptImport::UnderstandJob.perform_later(draft.id) }
    end
    # The tag snapshot rides the same single document fetch (M8 Task 6): PKs
    # resolve in ONE id__in call and are stored once — never per render.
    if link.tags.blank? && document.tag_ids.any?
      link.record_tags!(client.tag_names(document.tag_ids).values)
    end
  rescue Paperless::Error => e
    # A 401 is a rotation event, not a retry loop (spec §8.6): note it and give
    # up. Every other error is retried a bounded number of times; the row keeps
    # working (title/filename search) with no snapshot.
    raise e unless e.code == :unauthorized

    Paperless.note_token_invalid!
  end
end
