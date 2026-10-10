class CreateDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :document_links, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      # Filled when the paperless task succeeds; unique while present.
      t.bigint :paperless_document_id
      # Persisted so a restart can resume polling (see Task 4).
      t.string :paperless_task_id
      t.integer :poll_attempts, null: false, default: 0
      t.references :entry, null: true, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :account_statement, null: true, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :created_by, null: true, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :source, null: false
      t.string :status, null: false, default: "queued"
      t.integer :confidence
      t.string :title, limit: 500
      t.string :original_filename, limit: 255
      t.string :content_type, limit: 100
      t.string :content_sha256
      t.string :staged_path
      t.text :failure_message
      t.timestamps
    end

    add_index :document_links, :paperless_document_id, unique: true,
              where: "paperless_document_id IS NOT NULL",
              name: "index_document_links_on_paperless_document_id"
    add_index :document_links, [ :family_id, :status ], name: "index_document_links_on_family_and_status"
    add_index :document_links, [ :family_id, :content_sha256 ], unique: true,
              where: "content_sha256 IS NOT NULL",
              name: "index_document_links_family_content_sha256"

    add_check_constraint :document_links,
      "status IN ('queued','processing','unlinked','suggested','pending_review','linked','verified','dismissed','failed')",
      name: "chk_document_links_status"
    add_check_constraint :document_links,
      "source IN ('receipt','bill','statement','other')", name: "chk_document_links_source"
    add_check_constraint :document_links,
      "confidence IS NULL OR (confidence >= 0 AND confidence <= 100)", name: "chk_document_links_confidence"
    add_check_constraint :document_links,
      "content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$'", name: "chk_document_links_content_sha256"
    add_check_constraint :document_links,
      "title IS NULL OR char_length(title) <= 500", name: "chk_document_links_title_length"
  end
end
