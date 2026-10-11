# (repaired 2026-10-11, verifier F1) the column's migration lives with its
# first reader, the Row factory; Task 6 fills it.
class AddPaperlessTagsToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # The settle-time tag snapshot (M8 locked decision 6): the tag facet reads
    # stored names, never a per-render paperless call. Filled once by
    # Paperless::CaptureContentJob (Task 6); a re-run can only fill, never
    # overwrite.
    add_column :document_links, :paperless_tags, :text, array: true, default: [], null: false
    add_index :document_links, :paperless_tags, using: :gin
  end
end
