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
      draft.document_link.link_to_entry!(entry)
    end

    draft.document_link.broadcast_row_update!
  end
end
