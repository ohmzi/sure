class CreateAuditLogs < ActiveRecord::Migration[8.1]
  # Append-only record of financial edits. Rows are never updated or deleted
  # through the application; the model refuses both. `family_id` is repeated on
  # every row so a read can never cross a household boundary through the
  # auditable association alone, and the composite index serves the detail
  # pages' "activity for this record, newest first" query.
  def change
    create_table :audit_logs, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, null: true, foreign_key: { to_table: :users, on_delete: :nullify }

      t.string :auditable_type, null: false
      t.uuid :auditable_id, null: false

      t.string :action, null: false
      t.jsonb :before, null: false, default: {}
      t.jsonb :after, null: false, default: {}
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :audit_logs, [ :family_id, :auditable_type, :auditable_id, :created_at ],
              name: "index_audit_logs_on_family_and_auditable_and_created_at"
    add_index :audit_logs, [ :family_id, :created_at ]
  end
end
