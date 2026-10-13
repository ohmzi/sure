# frozen_string_literal: true

# Undoing a write the machine made on its own (spec N6).
#
# Refuses anything a human wrote. The affordance exists to reverse THIS
# program's decision, not to become a second way to delete transactions: a nil
# `ai_posted_at` is answered with 422 and the row is left byte-identical.
#
# The write goes through the ordinary destruction path (`Entry#destroy!`), which
# already detaches the entry's document links in a `before_destroy` callback
# (`Entry#unlink_document_links`), each scoped to its own id and to this entry.
# So the document survives its entry -- its bytes and its read stay the user's
# and it stays in the Documents grid -- rather than being destroyed by a button
# that says "undo". The balance is re-synced afterwards, exactly as the ordinary
# entry destroy does.
class Entries::AutoPostsController < ApplicationController
  def destroy
    entry = Current.family.entries
                       .joins(:account)
                       .merge(Account.accessible_by(Current.user))
                       .find(params[:entry_id])

    return unless require_account_permission!(entry.account)

    # A row a person typed is not the machine's to reverse.
    return head :unprocessable_content if entry.ai_posted_at.nil?

    # The document(s) this entry came from, captured BEFORE the destroy detaches
    # them (Entry's before_destroy :unlink_document_links). The undo must be
    # DURABLE: `data_committed?` is `entries.exists?`, so removing the entry
    # clears the draft's committed flag, and a reprocess would otherwise re-run
    # the gate and silently re-post what the user just took back. Recording the
    # reversal on the document -- the identity the auto-post is keyed on -- lets
    # the gate refuse it forever. The reviewed publish is untouched: redoing by
    # hand is still the user's call.
    #
    # Only the link the entry's OWN identity came from (review finding 5): the
    # auto-post writer mints `external_id "document:<link id>"`, so that link --
    # and only that link -- is the one whose reversal is durable. Marking EVERY
    # link on the entry would also stamp a statement that merely corroborated
    # this row, wrongly refusing a receipt later matched to that statement. If
    # the identity cannot be read (an unexpected shape), fall back to every link
    # so the reversal is never silently lost.
    documents = entry.document_links.to_a
    identity_link_id = entry.external_id.to_s[/\Adocument:(.*)\z/, 1]
    documents.select! { |link| link.id.to_s == identity_link_id } if identity_link_id.present?

    entry.destroy!                    # detaches its document links via before_destroy
    documents.each(&:mark_auto_post_undone!)
    entry.sync_account_later          # recompute the balance from the row that is gone

    redirect_back fallback_location: transactions_path, notice: t(".undone")
  end
end
