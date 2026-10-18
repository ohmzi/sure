class CreateRuleApplications < ActiveRecord::Migration[8.1]
  # One row per rule executed in an undoable apply-all batch. The batch id
  # groups the rules that ran together, so undoing a run can walk them in
  # reverse order. `changes` holds, per transaction id, the prior and applied
  # value of every attribute the rule actually changed; undo restores `from`
  # only when the current value still equals `to`.
  def change
    create_table :rule_applications, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :rule, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: true, foreign_key: { on_delete: :nullify }
      t.references :rule_run, type: :uuid, null: true, foreign_key: { on_delete: :nullify }

      t.uuid :batch_id, null: false
      t.datetime :applied_at, null: false
      t.datetime :undone_at
      t.uuid :undone_by_id
      t.string :status, null: false, default: "applied"
      t.jsonb :transaction_ids, null: false, default: []
      t.jsonb :attribute_changes, null: false, default: {}
      t.jsonb :skipped_transaction_ids, null: false, default: []

      t.timestamps
    end

    add_index :rule_applications, [ :family_id, :batch_id ]
    add_index :rule_applications, [ :rule_id, :applied_at ]
    add_index :rule_applications, :batch_id
    add_index :rule_applications, :undone_by_id
  end
end
