class AddReviewToAccountStatements < ActiveRecord::Migration[8.1]
  def change
    add_column :account_statements, :reviewed_at, :datetime
    add_column :account_statements, :reviewed_by_id, :uuid
    add_index :account_statements, :reviewed_by_id
    add_foreign_key :account_statements, :users, column: :reviewed_by_id, on_delete: :nullify
  end
end
