require "application_system_test_case"

# The owner (2026-10-19): on a phone the account menu "doesn't come down all
# the way", showing only Log out. The toolbar's frosted blur made the toolbar
# the box its fixed children are placed in, so the menu's bottom sheet sat at
# the toolbar's bottom edge, above the screen, rather than at the screen's.
class AccountMenuSheetTest < ApplicationSystemTestCase
  test "the account menu opens as a whole sheet at the bottom of a phone screen" do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit root_path

    within("nav.fixed.top-0") { find("[data-testid='user-menu'] [data-DS--popover-target='button']").click }
    panel = find("[data-testid='user-menu'] [data-DS--popover-target='content']", visible: true)
    sleep 0.6

    box = page.evaluate_script(<<~JS, panel)
      (el => { const r = el.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, height: innerHeight }; })(arguments[0])
    JS
    assert_operator box["top"], :>=, 0, "the sheet's top should be on screen, got #{box.inspect}"
    assert_in_delta box["height"], box["bottom"], 2, "the sheet should rest on the screen's bottom edge, got #{box.inspect}"
  end
end
