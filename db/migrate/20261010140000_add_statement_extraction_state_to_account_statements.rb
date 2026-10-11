class AddStatementExtractionStateToAccountStatements < ActiveRecord::Migration[8.1]
  def change
    # Only the extraction *outcome* lives here (R8). The paperless task id and
    # document id belong to the M1 DocumentLink spine (`source: "statement"`),
    # not to account_statements, so this migration adds one column and no
    # paperless identifiers.
    add_column :account_statements, :extraction_state, :string, null: false, default: "not_attempted"
  end
end
