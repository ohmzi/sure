# frozen_string_literal: true

# The native-intake column set (Task 1): the AI classification + OCR
# bookkeeping on document_links, the row -> extraction anchors on imports and
# import_rows, and the card identity the account resolver needs. Additive only —
# the destructive paperless drop is Task 12's.
class AddDocumentIntakeColumns < ActiveRecord::Migration[8.1]
  def change
    # --- document_links: the AI-written classification + OCR bookkeeping -----
    add_column :document_links, :classified_by, :string
    add_column :document_links, :classification_confidence, :decimal, precision: 5, scale: 4
    add_column :document_links, :page_count, :integer
    add_column :document_links, :ocr_engine, :string
    add_column :document_links, :ocr_started_at, :datetime
    add_column :document_links, :ocr_finished_at, :datetime

    # --- the two renames -----------------------------------------------------
    # A column called paperless_tags in a system with no paperless is a lie that
    # costs the next reader every time. Same for staged_path.
    rename_column :document_links, :paperless_tags, :tags
    rename_column :document_links, :staged_path, :stored_path

    # --- imports: the row -> extraction anchor -------------------------------
    add_reference :imports, :document_extraction, type: :uuid, null: true,
                  foreign_key: { to_table: :document_extractions, on_delete: :nullify }
    add_column :imports, :extraction_confidence, :decimal, precision: 5, scale: 4

    # --- import_rows: a row traces to a PLACE on a page ----------------------
    add_column :import_rows, :source_page, :integer
    add_column :import_rows, :source_coordinates, :jsonb

    # --- accounts: card identity (the resolver needs it; nothing has it today)
    add_column :accounts, :last4, :string
    add_column :accounts, :account_network, :string
    add_check_constraint :accounts, "last4 IS NULL OR char_length(last4) <= 4",
                         name: "chk_accounts_last4_length"
  end
end
