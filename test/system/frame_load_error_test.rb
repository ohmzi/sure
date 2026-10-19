require "application_system_test_case"

# The owner (2026-10-19): a part of a page that could not load — the server
# restarting mid-deploy, a dropped connection — showed Turbo's bare "Content
# missing" with no way on. It now says so in a card with Try again, which
# reloads just that part.
class FrameLoadErrorTest < ApplicationSystemTestCase
  test "a section that fails to load offers to try again" do
    sign_in users(:family_admin)
    visit root_path
    assert_selector "#merchant-breakdown-section select[name='category_id']"

    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/dashboard/merchant_breakdown*" ])

    find("#merchant-breakdown-section select[name='category_id']").find("option:not([selected])", match: :first).select_option

    within "turbo-frame#dashboard_merchant_breakdown" do
      assert_selector "[role=alert]", text: I18n.t("layouts.application.frame_error.title")
      assert_no_text "Content missing"
    end

    browser.execute_cdp("Network.setBlockedURLs", urls: [])
    within("turbo-frame#dashboard_merchant_breakdown") { click_on I18n.t("layouts.application.frame_error.retry") }

    assert_selector "#merchant-breakdown-section select[name='category_id']"
    assert_no_selector "turbo-frame#dashboard_merchant_breakdown [role=alert]"
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
  end
end
