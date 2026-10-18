require "test_helper"

# The account title is the switcher: tapping the name lists every accessible
# account, so changing accounts never needs the accounts index or a sidebar.
class UI::AccountPageHeaderTest < ViewComponent::TestCase
  setup do
    @account = accounts(:depository)
    Current.session = users(:family_admin).sessions.create!
  end

  teardown { Current.reset }

  test "the account title opens a switcher with the other accessible accounts" do
    other = accounts(:credit_card)
    paths = Rails.application.routes.url_helpers
    render_inline(UI::AccountPage.new(account: @account))

    assert_selector "button[aria-label='#{I18n.t("accounts.show.header.switch_account_named", account: @account.name)}']"
    assert_selector "a[href='#{paths.account_path(other)}']", visible: :all
    assert_selector "a[href='#{paths.account_path(@account)}'][aria-current='page']", visible: :all
  end
end
