class AddDestinationAccountToCategories < ActiveRecord::Migration[8.1]
  # The account a category's money goes to (the owner, 2026-10-19): label a
  # charge "Investment Contributions" and it becomes a transfer into the
  # investment account chosen here. Removing the account clears the link.
  def change
    add_reference :categories, :destination_account, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
