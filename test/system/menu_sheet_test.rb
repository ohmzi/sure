require "application_system_test_case"

# Every popup on a phone is the same bottom sheet (the owner's rule,
# 2026-10-17), DS::Menu included: pinned to the bottom edge over a backdrop
# that only an open menu shows, and that closes it when tapped.
class MenuSheetTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  test "a menu opens as a bottom sheet on a phone, and its backdrop closes it" do
    visit transactions_path
    menu_button = first("[data-controller~='DS--menu'] button[aria-haspopup='menu']")
    assert_no_selector "[data-ds--menu-target='backdrop']:not(.hidden)" # nothing covers the page while closed

    menu_button.click
    assert_selector "[data-ds--menu-target='content'][data-sheet]:not(.hidden)"
    assert_selector "[data-ds--menu-target='backdrop']:not(.hidden)"

    find("[data-ds--menu-target='backdrop']:not(.hidden)").click(x: 0, y: -280) # near the top, clear of the sheet
    assert_no_selector "[data-ds--menu-target='content']:not(.hidden)"
    assert_no_selector "[data-ds--menu-target='backdrop']:not(.hidden)"
  end
end
