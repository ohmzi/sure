module EnvelopesHelper
  # Accounts with a live balance, for the surface's accounts column.
  def self.account_columns(budget)
    accounts = budget.family.accounts.visible.included_in_reports.order(:name)
    accounts = accounts.where(owner_id: budget.user_id) if budget.user_id.present?
    accounts.group_by(&:classification).map do |classification, grouped|
      { classification: classification, accounts: grouped }
    end
  end
end
