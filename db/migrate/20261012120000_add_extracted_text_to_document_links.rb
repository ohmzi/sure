class AddExtractedTextToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # The local OCR-text snapshot (M7 locked decision 8). Filled once when the
    # link settles; the row is immutable afterwards, so there is no
    # invalidation problem. Nullable: queued/failed rows have no text yet.
    add_column :document_links, :extracted_text, :text
  end
end
