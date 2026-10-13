# frozen_string_literal: true

class AddAiPostedAtToEntries < ActiveRecord::Migration[8.1]
  def change
    # Justified new column: auto-posted money must be FINDABLE, and findability
    # is what makes shipping the gate live safe (spec N6/N13). Nothing existing
    # means "a machine wrote this". Nullable, so every historical row is
    # unaffected, with a partial index because the flagged rows are a tiny
    # minority and the ledger filter queries exactly them.
    add_column :entries, :ai_posted_at, :datetime
    add_index :entries, :ai_posted_at, where: "ai_posted_at IS NOT NULL"
  end
end
