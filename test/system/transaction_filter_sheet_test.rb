require "application_system_test_case"

# The filter sheet on a phone (the owner's design, 2026-10-19): a Filters
# heading, the account list as one card with a Select all, and an Apply that
# counts what is checked.
class TransactionFilterSheetTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit transactions_path
  end

  test "the phone sheet lists accounts, selects them all and applies the filter" do
    account_count = @user.accessible_accounts.count
    assert_operator account_count, :>, 0

    find("#transaction-filters-button").click

    assert_selector "h2", text: I18n.t("transactions.searches.menu.title"), visible: :visible
    assert_selector "input[name='q[accounts][]']", count: account_count, visible: :visible

    click_button I18n.t("transactions.searches.menu.select_all")
    assert_selector "button", exact_text: I18n.t("transactions.searches.menu.apply_count", count: account_count), visible: :visible

    click_button I18n.t("transactions.searches.menu.apply_count", count: account_count)

    assert_current_path(/q(%5B|\[)accounts/, url: true)
  end
end
