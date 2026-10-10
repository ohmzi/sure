class AddTargetsToBudgetCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :budget_categories, :target_amount, :decimal, precision: 19, scale: 4
    add_column :budget_categories, :target_type, :string
    add_column :budget_categories, :target_date, :date

    add_check_constraint :budget_categories,
      "target_type IS NULL OR target_type IN ('monthly_assign','savings_balance','savings_by_date','needed_for_spending')",
      name: "chk_budget_categories_target_type"
    add_check_constraint :budget_categories,
      "target_amount IS NULL OR target_amount >= 0",
      name: "chk_budget_categories_target_amount_non_negative"
  end
end
