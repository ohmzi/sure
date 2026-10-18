require "application_system_test_case"

class CashFlowGroupByTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @month = Date.current.beginning_of_month
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    category = @user.family.categories.create!(name: "Group By Shopping", color: "#123456")
    account = @user.family.accounts.create!(name: "Group By Checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: account, category: category, amount: 100, date: @month)
  end

  test "the account flow is the default and switching back to categories is remembered" do
    sign_in @user
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-preview [data-preview-sankey-chart-target='chart']", match: :first)
    assert_selector "#cashflow-preview svg .sankey-link"
    assert_selector "#cashflow-preview svg text", text: "Group By Checking"
    assert_nil find("#cashflow-preview")["data-sankey-comparison"].presence, "the account view is not compared with the legacy category chart"

    within("#cashflow-preview") { click_button "Category" }

    chart.assert_no_selector "svg text", text: "Group By Checking"
    assert_selector "#cashflow-preview button[aria-pressed='true']", text: "Category"

    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    find("#cashflow-preview [data-preview-sankey-chart-target='chart']", match: :first)
      .assert_no_selector "svg text", text: "Group By Checking"
    assert_equal "category", @user.reload.cashflow_sankey_group_by
  end
end
