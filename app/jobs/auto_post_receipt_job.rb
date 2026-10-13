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
    return unless Setting.auto_post_receipts?

    linked = false

    draft.with_lock do
      # Every judgement below is made on the draft `with_lock` just RELOADED
      # (W3-3), so the gate is never separated from the values actually written:
      # a value that changed between the job's first read and this lock (a manual
      # edit, a fresh read) is judged as it now stands, not as it was.
      link = draft.document_link
      return if link.nil?
      return unless AutoPost.allowed?(draft: draft, extraction: link.extraction)
      return if draft.data_committed?

      # W3-4: a document already committed to an entry is done. Never mint a
      # second entry for it, and never STEAL the existing edge by re-pointing the
      # link at a new one.
      return if link.entry_id.present?

      if (existing = existing_entry_for(draft))
        # W3-1 (statement-first ordering): the account already holds this charge,
        # so the receipt CORROBORATES it (spec §8.6) instead of minting a
        # duplicate. If the edge cannot be recorded safely, this is a refusal —
        # fall to review and write no money rather than commit a second entry.
        return unless link.link_to_entry!(existing, from: DocumentLink::PUBLISH_LINKABLE)
        linked = true
      else
        entry = Account::ProviderImportAdapter.new(draft.account).import_transaction(
          external_id: "document:#{link.id}",
          source: "document",
          amount: draft.total_amount,
          # Import#default_currency is private; this is its exact rule
          # (account&.currency || family.currency), written out so the job can read
          # it through a public path. The gate has already guaranteed the account.
          currency: draft.account.currency || draft.family.currency,
          date: draft.purchase_date,
          name: draft.payee.presence || link.title.presence || "Receipt",
          allow_heuristic_matching: false
        )
        entry.update!(import: draft, import_locked: true, ai_posted_at: Time.current)

        # The provenance edge is not optional: an auto-posted entry with no document
        # is exactly the provenance gap this milestone exists to close. Same shape
        # as the reviewed publish — the write accepts PUBLISH_LINKABLE (a link the
        # user DISMISSED in the reconciliations inbox is still a link this write
        # must record), and a refusal RAISES inside the lock so the money rolls back
        # rather than committing an entry with no edge.
        unless link.link_to_entry!(entry, from: DocumentLink::PUBLISH_LINKABLE)
          raise "could not record the document provenance edge on #{link.id}"
        end
        linked = true
      end
    end

    draft.document_link.reload.broadcast_row_update! if linked
  end

  private
    # The entry the account already holds for the charge this receipt is evidence
    # of, if any (W3-1, spec N6/N13): the adapter's own reconciliation window —
    # same amount and currency, a date within ±3 days. `include_provider_entries`
    # because the existing charge may have arrived by bank sync or from a
    # statement, not only by hand, and every one of those is money already
    # written for this charge.
    def existing_entry_for(draft)
      Account::ProviderImportAdapter.new(draft.account).find_duplicate_transaction(
        date: draft.purchase_date,
        amount: draft.total_amount,
        currency: draft.account.currency || draft.family.currency,
        date_window: 3,
        include_provider_entries: true
      )
    end
end
