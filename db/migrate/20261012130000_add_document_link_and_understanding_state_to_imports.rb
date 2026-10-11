class AddDocumentLinkAndUnderstandingStateToImports < ActiveRecord::Migration[8.1]
  def change
    # The receipt/bill draft's spine row (M7 decision 2). Nullable: every other
    # Import subtype has no document. Nullify on delete so removing a link
    # leaves the draft's audit trail intact.
    add_reference :imports, :document_link, type: :uuid, null: true,
                  foreign_key: { to_table: :document_links, on_delete: :nullify }

    # OCR understanding state for a receipt/bill draft (M7 decision: never a
    # guess). Null for every other import type; only ReceiptImport validates it.
    add_column :imports, :understanding_state, :string
    add_check_constraint :imports,
      "understanding_state IS NULL OR understanding_state IN ('awaiting_ocr','understood','needs_understanding')",
      name: "chk_imports_understanding_state"
  end
end
