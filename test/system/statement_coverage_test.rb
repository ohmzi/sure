require "application_system_test_case"

# The statements tab's month grid: each month is a link in the tab order, and
# the grid controller adds arrow-key movement without taking any month out of
# the accessible tree.
class StatementCoverageTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    # The "what's new" dialog opens on the first keydown and takes focus. A
    # focus-navigation test must not race it, so mark this release seen.
    if (tag = ReleaseHighlights.pending_tag_for(@user))
      @user.mark_release_seen!(tag)
    end
  end

  test "arrow keys move focus across the labelled month grid" do
    visit account_path(@account, tab: "statements")

    grid = find("[data-controller='month-grid']")
    assert_equal I18n.t("account_statements.account_tab.months_label"), grid["aria-label"]
    assert_equal "group", grid["role"]

    links = grid.all("a[href]")
    assert_operator links.size, :>=, 2, "the coverage year must render at least two months"

    assert_equal links[1]["aria-label"], press_key(links.first, "ArrowRight"),
                 "ArrowRight should move focus to the next month"

    assert_equal links.first["aria-label"], press_key(links[1], "ArrowLeft"),
                 "ArrowLeft should move focus back to the first month"

    assert_equal links.last["aria-label"], press_key(links[1], "End"),
                 "End should move focus to the last month"

    assert_equal links.first["aria-label"], press_key(links.last, "Home"),
                 "Home should move focus back to the first month"
  end

  private
    # W3C keyboard events, dispatched from the focused cell. The focused label
    # is read in the same script: the account page's lazy dropdown frames
    # connect list-filter controllers that focus their own search inputs at
    # unpredictable times, and a separate round trip could let one land
    # between the dispatch and the assertion. Selenium's send_keys also moves
    # through the browser's own shortcuts, so the grid's contract is just the
    # keydown handler.
    def press_key(element, key)
      page.execute_script(<<~JS, element.native, key)
        arguments[0].focus();
        arguments[0].dispatchEvent(new KeyboardEvent("keydown", { key: arguments[1], bubbles: true }));
        return document.activeElement.getAttribute("aria-label");
      JS
    end
end
