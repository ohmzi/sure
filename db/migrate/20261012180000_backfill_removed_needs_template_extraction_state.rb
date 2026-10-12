# frozen_string_literal: true

# Task 12 removed the `needs_template` value from AccountStatement's
# extraction_state enum but did not migrate the rows that held it. A row with an
# unknown value reads back as nil and fails validation on re-save. The single
# affected row was "uploaded but the template matcher could not extract it" — the
# native read never attempted it, so `not_attempted` (the column default) is the
# honest current state, and it also makes the statement eligible for a native
# re-read. Only that one legacy value is touched.
class BackfillRemovedNeedsTemplateExtractionState < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE account_statements
      SET extraction_state = 'not_attempted'
      WHERE extraction_state = 'needs_template'
    SQL
  end

  def down
    # Not reversible: 'needs_template' no longer exists in the enum.
    raise ActiveRecord::IrreversibleMigration
  end
end
