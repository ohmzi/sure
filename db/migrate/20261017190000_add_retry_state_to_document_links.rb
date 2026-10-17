class AddRetryStateToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # Durable retry state for the native document read (2026-10-17). The
    # DocumentLink row is the source of truth: a lost Sidekiq job or a reboot
    # must not lose a document, so attempts, the next due time and the failure's
    # class live here rather than in Redis.
    add_column :document_links, :attempts_count, :integer, default: 0, null: false
    add_column :document_links, :next_attempt_at, :datetime
    add_column :document_links, :failure_code, :string

    add_index :document_links, [ :status, :next_attempt_at ]
    add_index :document_links, [ :status, :failure_code ]
  end
end
