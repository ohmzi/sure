# frozen_string_literal: true

# THE ONLY money writer in this program that runs without a human clicking
# (spec N6). Everything about it is defensive: it re-checks the gate at write
# time rather than trusting its caller, it goes through the same sanctioned
# adapter every other writer uses, and it mints the same replay-safe identity
# the reviewed publish mints — so an auto-post and a manual publish of the same
# document cannot produce two entries.
class AutoPostReceiptJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(receipt_import_id)
    draft = ReceiptImport.find(receipt_import_id)
    return if draft.document_link.nil?

    # Only a RECEIPT auto-posts. A receipt is evidence of payment — if it
    # exists, the money moved. A BILL is an invoice that may be unpaid, and
    # auto-posting it would write an expense that never happened. N6 grants
    # auto-post to receipts; a bill is read and drafted, then waits for the one
    # tap. Checked here (not only at the enqueue site) so the writer never trusts
    # its caller.
    return unless draft.document_link.receipt?

    extraction = draft.document_link.extraction
    return unless AutoPost.allowed?(draft: draft, extraction: extraction)
    return unless Setting.auto_post_receipts?
    return if draft.data_committed?

    draft.with_lock do
      return if draft.data_committed?

      entry = Account::ProviderImportAdapter.new(draft.account).import_transaction(
        external_id: "document:#{draft.document_link.id}",
        source: "document",
        amount: draft.total_amount,
        # Import#default_currency is private; this is its exact rule
        # (account&.currency || family.currency), written out so the job can read
        # it through a public path. The gate has already guaranteed the account.
        currency: draft.account.currency || draft.family.currency,
        date: draft.purchase_date,
        name: draft.payee.presence || draft.document_link.title.presence || "Receipt",
        allow_heuristic_matching: false
      )
      entry.update!(import: draft, import_locked: true, ai_posted_at: Time.current)

      # The provenance edge is not optional: an auto-posted entry with no document
      # is exactly the provenance gap this milestone exists to close. Same shape
      # as the reviewed publish — the write accepts PUBLISH_LINKABLE (a link the
      # user DISMISSED in the reconciliations inbox is still a link this write
      # must record), and a refusal RAISES inside the lock so the money rolls back
      # rather than committing an entry with no edge.
      unless draft.document_link.link_to_entry!(entry, from: DocumentLink::PUBLISH_LINKABLE)
        raise "could not record the document provenance edge on #{draft.document_link.id}"
      end
    end

    draft.document_link.broadcast_row_update!
  end
end
