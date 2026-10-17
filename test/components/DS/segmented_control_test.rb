require "test_helper"

class DS::SegmentedControlTest < ViewComponent::TestCase
  test "renders segments as buttons by default with the base + active classes" do
    render_inline(DS::SegmentedControl.new) do |sc|
      sc.with_segment("All", active: true)
      sc.with_segment("Over Budget")
    end

    assert_selector "div.segmented-control[role=group]"
    assert_selector "button.segmented-control__segment", count: 2
    assert_selector "button.segmented-control__segment--active", text: "All", count: 1
    refute_selector "button.segmented-control__segment--active", text: "Over Budget"
  end

  test "href renders a segment as a link" do
    render_inline(DS::SegmentedControl.new) do |sc|
      sc.with_segment("Sign in", href: "/login", active: true)
      sc.with_segment("Sign up", href: "/join")
    end

    assert_selector "a.segmented-control__segment--active[href='/login']", text: "Sign in"
    assert_selector "a.segmented-control__segment[href='/join']", text: "Sign up"
  end

  test "full_width stretches the track and each segment" do
    render_inline(DS::SegmentedControl.new(full_width: true)) do |sc|
      sc.with_segment("One", active: true)
      sc.with_segment("Two")
    end

    assert_selector "div.segmented-control.w-full"
    assert_selector "button.segmented-control__segment.flex-1", count: 2
  end

  test "aria_label and passthrough attrs land on the wrapper" do
    render_inline(DS::SegmentedControl.new(aria_label: "Filter", data: { controller: "x" })) do |sc|
      sc.with_segment("A", active: true)
    end

    assert_selector "div.segmented-control[aria-label='Filter'][data-controller='x']"
  end

  test "per-segment passthrough class and data merge onto the segment" do
    render_inline(DS::SegmentedControl.new) do |sc|
      sc.with_segment("A", active: true, class: "custom-x", data: { id: "a" })
    end

    assert_selector "button.segmented-control__segment--active.custom-x[data-id='a']"
  end

  # The sliding pill (opt-in): one indicator moves between segments instead of
  # each segment painting its own active background, the iOS behaviour.
  test "sliding renders one indicator and marks the active segment without its own pill" do
    render_inline(DS::SegmentedControl.new(sliding: true, full_width: true)) do |sc|
      sc.with_segment("All", href: "/a", active: true)
      sc.with_segment("Statements", href: "/b")
    end

    assert_selector "div.segmented-control[data-controller~='segmented-slide']"
    assert_selector "[data-segmented-slide-target='indicator']", count: 1
    assert_selector "a[data-segmented-slide-target='segment']", count: 2
    assert_selector "a[aria-current='true'][data-active='true']", text: "All"
    assert_no_selector ".segmented-control__segment--active"
  end
end
