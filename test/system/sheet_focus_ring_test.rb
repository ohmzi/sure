require "application_system_test_case"

# The owner (2026-10-19): sheets should look finished. Opening one moved
# focus to its first control, the close button, and drew the keyboard focus
# ring round it, so most sheets opened with a ringed close button that no one
# had reached with a keyboard.
class SheetFocusRingTest < ApplicationSystemTestCase
  test "a sheet opens without a focus ring on its close button" do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit new_transaction_path

    close = find("dialog[open] header button[aria-label='#{I18n.t("ds.dialog.close")}']")
    sleep 0.3
    assert page.evaluate_script("document.activeElement === arguments[0]", close), "focus should still start on the close button"
    assert_not page.evaluate_script("arguments[0].matches(':focus-visible')", close), "the close button should not show the keyboard focus ring"
  end
end
