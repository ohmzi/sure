class RelaxBudgetCategoryRolledOverAmountConstraint < ActiveRecord::Migration[8.1]
  # A negative carry now follows the envelope forward (spec 9.2), so the
  # v1-only non-negative guard has to go. The column stays NOT NULL. Written
  # as up/down rather than a reversible `change`: `remove_check_constraint`
  # can only invert the drop when it is handed the dropped expression, and the
  # schema stores it as `rolled_over_amount >= 0::numeric`.
  def up
    remove_check_constraint :budget_categories,
                            name: "chk_budget_categories_rolled_over_amount_non_negative"
  end

  def down
    add_check_constraint :budget_categories, "rolled_over_amount >= 0",
                         name: "chk_budget_categories_rolled_over_amount_non_negative"
  end
end
