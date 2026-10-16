# frozen_string_literal: true

class AddCurrencyToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # The currency the owner chose when uploading a receipt or bill (the owner's
    # rule, 2026-10-16): blank means the family's display currency. Statements
    # ignore it — a statement's money is in its account's currency.
    add_column :document_links, :currency, :string, limit: 3
  end
end
