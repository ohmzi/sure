class AddProcessingOwnerToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # Which Sidekiq process claimed the read. A boot/reaper sweep can tell an
    # orphaned row (its process is gone) from a live one without waiting out the
    # full heartbeat lease.
    add_column :document_links, :processing_owner, :string
    add_index :document_links, [ :status, :processing_owner ]
  end
end
