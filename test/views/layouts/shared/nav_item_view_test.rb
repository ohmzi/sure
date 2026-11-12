require "test_helper"

class NavItemViewTest < ActionView::TestCase
  test "active nav item carries aria-current=\"page\"" do
    html = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions",
      path: "/transactions",
      icon: "credit-card",
      icon_custom: false,
      active: true
    })

    assert_includes html, "aria-current=\"page\""
  end

  test "inactive nav item omits aria-current" do
    html = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions",
      path: "/transactions",
      icon: "credit-card",
      icon_custom: false,
      active: false
    })

    assert_not_includes html, "aria-current"
  end

  # The active look follows aria-current (2026-10-17), so nav_press_controller
  # can light a tapped item up at once, before the next page has arrived.
  test "the active look is keyed on aria-current, not baked into the markup" do
    active = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions", path: "/transactions", icon: "credit-card", icon_custom: false, active: true
    })
    inactive = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions", path: "/transactions", icon: "credit-card", icon_custom: false, active: false
    })

    assert_includes inactive, "group-aria-[current=page]:text-link"
    assert_equal active.gsub(' aria-current="page"', ""), inactive
  end

  # The layout filters desktop-only items out of the bottom bar; the partial
  # itself accepts the flag and draws the same link with or without it.
  test "desktop_only defaults off and leaves the item's markup unchanged" do
    locals = { name: "Reports", path: "/reports", icon: "chart-bar", icon_custom: false, active: false }

    without_flag = render(partial: "layouts/shared/nav_item", locals: locals)

    assert_equal without_flag, render(partial: "layouts/shared/nav_item", locals: locals.merge(desktop_only: false))
    assert_equal without_flag, render(partial: "layouts/shared/nav_item", locals: locals.merge(desktop_only: true))
  end
end
