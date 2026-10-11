# frozen_string_literal: true

# Wizard screen 3's prefill ladder (locked decision 5 / owner request):
#   1. exactly one accessible visible account -> it (there is nothing to choose);
#   2. otherwise the user's bills default (users.default_account_id, re-checked
#      for eligibility by User#default_account_for_bills);
#   3. otherwise nothing -> the select renders blank and is mandatory.
# Pure and injectable: no Current, no controller state.
class Import::AccountPrefill
  Result = Data.define(:account, :reason) do
    def selected_id = account&.id
    def none? = account.nil?
  end

  def self.call(user:)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    accounts = @user.accessible_accounts.visible.to_a
    return Result.new(account: accounts.first, reason: :only_account) if accounts.one?

    default = @user.default_account_for_bills
    if default.present? && accounts.include?(default)
      return Result.new(account: default, reason: :default_account)
    end

    Result.new(account: nil, reason: :none)
  end
end
