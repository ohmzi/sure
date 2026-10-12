require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "create falls back to the stored return_to when no form param is present" do
    get new_account_path(return_to: transactions_path) # StoreLocation captures it into the session

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "Return To Checking", currency: "USD", balance: 100, accountable_type: "Depository" }
      }
    end

    assert_redirected_to transactions_path
  end

  test "create prefers the form return_to over the session value" do
    get new_account_path(return_to: transactions_path) # session return_to

    post depositories_path, params: {
      account: { name: "Form RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: budgets_path }
    }

    assert_redirected_to budgets_path
  end

  test "create ignores an external return_to (open-redirect guard)" do
    post depositories_path, params: {
      account: { name: "Evil RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: "https://evil.example/phish" }
    }

    created = Account.order(:created_at).last
    assert_redirected_to account_path(created) # not the external URL
  end

  test "update persists enable_category_matcher through the shared update action" do
    linked_account = accounts(:connected)
    assert linked_account.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "0" }
    }

    refute linked_account.reload.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "1" }
    }

    assert linked_account.reload.enable_category_matcher?
  end

  test "edit form renders category matcher toggle only for accounts that support it" do
    get edit_account_url(accounts(:connected))
    assert_response :success
    assert_select "input[type=checkbox][name='account[enable_category_matcher]']", 1

    get edit_account_url(accounts(:depository))
    assert_response :success
    assert_select "input[name='account[enable_category_matcher]']", 0
  end

  test "update persists card last4 and network through the shared update action" do
    patch depository_path(@account), params: {
      account: { last4: "4242", account_network: "visa" }
    }

    @account.reload
    assert_equal "4242", @account.last4
    assert_equal "visa", @account.account_network
  end

  test "edit form renders the card identity fields" do
    get edit_account_url(@account)
    assert_response :success

    assert_select "input[name='account[last4]'][maxlength='4'][inputmode='numeric']", 1
    assert_select "select[name='account[account_network]'] option[value='visa']", 1
  end

  test "update accepts blank card identity fields" do
    # The form always submits both fields, empty for a non-card account; a
    # blank submission must not 422 the whole account update.
    patch depository_path(@account), params: {
      account: { name: @account.name, last4: "", account_network: "" }
    }

    assert_response :redirect
    assert_nil @account.reload.last4
    assert_nil @account.account_network
    assert_not @account.card_identity?
  end

  # --- member-owned connections (issue #3579) ------------------------------

  test "a member sees only member-connectable providers in the method selector" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(stub("plaid"))
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(true)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_member)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_plaid_item_path(region: "us", accountable_type: "Depository"), count: 1
    # SimpleFIN is tenant-wide, so it must not be offered to a member even
    # when it is configured.
    assert_select "a[href*=?]", "simplefin", count: 0
  end

  test "an admin still sees every configured provider in the method selector" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(stub("plaid"))
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(true)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_admin)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_plaid_item_path(region: "us", accountable_type: "Depository"), count: 1
  end

  test "a member is offered manual entry even with no connectable providers" do
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(false)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_member)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_depository_path, count: 1
  end
end
