require "application_system_test_case"

# The Settings audit (the owner, 2026-10-19): a search field narrows the
# Settings list as you type, and says so when nothing matches.
class SettingsSearchTest < ApplicationSystemTestCase
  test "typing narrows the settings list" do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit settings_root_path

    find("input[type=search]").fill_in(with: "cat")
    assert_link I18n.t("settings.settings_nav.categories_label")
    assert_no_link I18n.t("settings.settings_nav.appearance_label")

    find("input[type=search]").fill_in(with: "zzzz")
    assert_text I18n.t("settings.settings_nav.no_results")
  end
end
