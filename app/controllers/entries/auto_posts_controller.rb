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

    entry.destroy!           # detaches its document links via before_destroy
    entry.sync_account_later # recompute the balance from the row that is gone

    redirect_back fallback_location: transactions_path, notice: t(".undone")
  end
end
