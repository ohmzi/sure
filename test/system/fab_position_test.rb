require "application_system_test_case"

# The owner (2026-10-19): the + button sits in the same place on every page.
# A responsive (@container) wrapper becomes the containing block of a fixed
# child, which lifted the Documents button 16px above the others.
class FabPositionTest < ApplicationSystemTestCase
  test "the + button sits in the same place on every page" do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)

    # Settings' lists add with the same button (the owner, 2026-10-19: "the +
    # button should be a FAB at bottom right like other screens").
    positions = %w[/transactions /accounts /documents /categories /tags /family_merchants /rules /settings/api_keys /imports /family_exports /settings/household].to_h do |path|
      visit path
      assert_selector "[data-controller~='floating-action']", visible: :all
      [ path, page.evaluate_script(<<~JS) ]
        (() => { const r = document.querySelector("[data-controller~='floating-action']").getBoundingClientRect();
                 return [Math.round(r.right), Math.round(r.bottom)]; })()
      JS
    end

    assert_equal 1, positions.values.uniq.size, positions.inspect
  end
end
