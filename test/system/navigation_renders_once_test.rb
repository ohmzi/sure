require "application_system_test_case"

# The owner (2026-10-18): Activity "loads twice". Turbo painted its cached copy
# of a page first and then the fresh one, so a screen opened again appeared,
# then appeared again, its charts playing their entrance on each. A tap now
# keeps the current screen until the new one has arrived and draws it once;
# Back and Forward still restore from the cache at once.
class NavigationRendersOnceTest < ApplicationSystemTestCase
  test "opening a screen again draws it once, not a cached copy first" do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit root_path

    open_tab("clear_filters")
    open_tab_home
    page.execute_script(<<~JS)
      window.__renders = [];
      document.addEventListener("turbo:before-render", () =>
        window.__renders.push(document.documentElement.hasAttribute("data-turbo-preview") ? "preview" : "fresh"));
    JS
    open_tab("clear_filters")

    assert_equal [ "fresh" ], page.evaluate_script("window.__renders")
  end

  private
    def open_tab(href_part)
      find("nav a[href*='#{href_part}']", match: :first).click
      assert_selector "h1", text: I18n.t("transactions.index.title")
    end

    def open_tab_home
      find("nav a[href='/']", match: :first).click
      assert_no_selector "h1", text: I18n.t("transactions.index.title")
      sleep 0.3
    end
end
