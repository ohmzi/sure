require "test_helper"

class Import::AccountPrefillTest < ActiveSupport::TestCase
  test "a single accessible account prefills regardless of the default" do
    user = users(:family_member)
    user.update!(default_account: nil)
    # family_member's only other share is read-only; drop it so exactly one
    # accessible visible account remains.
    account_shares(:credit_card_shared_with_member).destroy!
    result = Import::AccountPrefill.call(user: user)

    assert_equal :only_account, result.reason
    assert_equal accounts(:depository), result.account
    assert_equal result.account.id, result.selected_id
  end

  test "with several accounts the bills default prefills" do
    user = users(:family_admin)
    user.update!(default_account: accounts(:depository))

    result = Import::AccountPrefill.call(user: user)

    assert_equal :default_account, result.reason
    assert_equal accounts(:depository), result.account
  end

  test "with several accounts and no default the screen is blank and mandatory" do
    user = users(:family_admin)
    user.update!(default_account: nil)

    result = Import::AccountPrefill.call(user: user)

    assert_equal :none, result.reason
    assert_nil result.account
    assert_nil result.selected_id
  end
end
