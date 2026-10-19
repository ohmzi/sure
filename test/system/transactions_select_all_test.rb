require "application_system_test_case"

# The owner (2026-10-19): on a phone, with the row checkboxes showing, one tap
# selects every transaction on the page, and unticking a row unticks it.
class TransactionsSelectAllTest < ApplicationSystemTestCase
  test "a phone selects every transaction on the page at once" do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit transactions_path

    find("#toggle-checkboxes-button").click
    select_all = find("#select_all_on_page", visible: true)
    rows = all("input[data-bulk-select-target='row']:not([disabled])", visible: :all).size

    select_all.click

    within "#entry-selection-bar" do
      assert_text(/#{rows}\s+#{I18n.t("transactions.list.transactions")}/)
    end

    first("input[data-bulk-select-target='row']", visible: true).click
    assert_not select_all.checked?
  end
end
