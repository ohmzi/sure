require "application_system_test_case"

# The statements tab's month grid: each month is a link in the tab order, and
# the grid controller adds arrow-key movement without taking any month out of
# the accessible tree.
class StatementCoverageTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "arrow keys move focus across the labelled month grid" do
    visit account_path(@account, tab: "statements")

    grid = find("[data-controller='month-grid']")
    assert_equal I18n.t("account_statements.account_tab.months_label"), grid["aria-label"]
    assert_equal "group", grid["role"]

    links = grid.all("a[href]")
    assert_operator links.size, :>=, 2, "the coverage year must render at least two months"

    press_key(links.first, "ArrowRight")
    assert_equal links[1]["aria-label"],
                 page.evaluate_script("document.activeElement.getAttribute('aria-label')"),
                 "ArrowRight should move focus to the next month"

    press_key(links[1], "ArrowLeft")
    assert_equal links.first["aria-label"],
                 page.evaluate_script("document.activeElement.getAttribute('aria-label')"),
                 "ArrowLeft should move focus back to the first month"
  end

  private
    # W3C keyboard events, dispatched from the focused cell. Selenium's
    # send_keys also moves through the browser's own shortcuts, which makes a
    # focus assertion depend on the page's search box; the grid's contract is
    # just the keydown handler.
    def press_key(element, key)
      page.execute_script("arguments[0].focus()", element.native)
      page.execute_script(
        "arguments[0].dispatchEvent(new KeyboardEvent('keydown', { key: arguments[1], bubbles: true }))",
        element.native, key
      )
    end
end
