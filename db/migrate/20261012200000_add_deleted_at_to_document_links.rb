# frozen_string_literal: true

class AddDeletedAtToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # Justified: a document must be deletable WITHOUT the transaction it
    # produced forgetting where it came from. A hard destroy would drop the link
    # row, and the provenance resolver would then read that entry as
    # hand-entered -- a silent lie about the user's own ledger. Nullable, so
    # every existing row keeps working; the partial index covers the one query
    # that asks for the tombstones (they are excluded from every archive read,
    # so they are a tiny minority).
    add_column :document_links, :deleted_at, :datetime
    add_index :document_links, :deleted_at, where: "deleted_at IS NOT NULL"

    # Justified (carried in from Task 9): an auto-post the user undid must not
    # silently re-post when the document is reprocessed. Auto-post is live, so
    # its undo is meant to carry the weight -- but the draft's committed flag is
    # computed from `entries.exists?`, which the undo clears. The durable fact
    # "this document's auto-post was reversed" needs somewhere to live, and the
    # document link is the identity the auto-post is keyed on
    # (`document:<link id>`). Nullable, so every historical row is unaffected.
    add_column :document_links, :auto_post_undone_at, :datetime
  end
end
