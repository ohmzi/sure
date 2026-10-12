# frozen_string_literal: true

# The read provenance table (native intake Task 1): one row per read of a
# document. Anchors every extracted Import::Row to the exact read that produced
# it, so a row is traceable to its source document AND to the model that read it.
class CreateDocumentExtractions < ActiveRecord::Migration[8.1]
  def change
    create_table :document_extractions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :document_link, null: false, type: :uuid, foreign_key: { on_delete: :cascade }

      t.string :provider
      t.string :model
      t.string :ocr_engine
      t.integer :page_count, null: false, default: 0

      t.text :ocr_text
      t.jsonb :raw_response, null: false, default: {}
      t.jsonb :verdict, null: false, default: {}
      t.jsonb :field_confidence, null: false, default: {}
      t.jsonb :validations, null: false, default: {}

      t.string :status, null: false, default: "pending"
      t.text :error

      t.timestamps
    end

    # The "latest read for this link" lookup (DocumentLink#extraction), ordered
    # by created_at desc.
    add_index :document_extractions, [ :document_link_id, :created_at ]
    add_check_constraint :document_extractions, "status IN ('pending','succeeded','failed')",
                         name: "chk_document_extractions_status"
  end
end
