require "test_helper"

# The owner (2026-10-18): the page changer shows five pages from the current
# one, then "…", then the last page — the same everywhere a list pages, on a
# phone too.
class PaginationHelperTest < ActionView::TestCase
  include PaginationHelper

  def window(page, pages)
    pagination_window(page: page, pages: pages).map { |item| item == :gap ? "…" : item.to_s }.join(" ")
  end

  test "a list of few pages shows them all" do
    assert_equal "1", window(1, 1)
    assert_equal "1 2 3", window(2, 3)
    assert_equal "1 2 3 4 5 6", window(1, 6)
  end

  test "the first page shows one to five, then the last" do
    assert_equal "1 2 3 4 5 … 311", window(1, 311)
  end

  test "a later page shows the five from it, then the last" do
    assert_equal "7 8 9 10 11 … 311", window(7, 311)
  end

  test "a window that reaches the page before the last runs on into it" do
    assert_equal "306 307 308 309 310 311", window(306, 311)
  end

  test "near the end it shows the last five" do
    assert_equal "307 308 309 310 311", window(309, 311)
    assert_equal "307 308 309 310 311", window(311, 311)
  end
end
