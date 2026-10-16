require "application_system_test_case"

# The owner's ask (2026-10-16): a balance line is coloured segment by segment by
# what is good for the account — a credit card's debt coming down green, going
# up red; cash the other way — and dims past the hover point instead of greying.
class AccountChartTrendColorsTest < ApplicationSystemTestCase
  test "a credit card's chart draws its line from per-segment colour stops, full and dimmed" do
    sign_in users(:family_admin)

    visit account_url(accounts(:credit_card))

    within "#lineChart" do
      assert_selector "linearGradient[id$='-split-gradient'] stop", visible: :all, minimum: 1
      assert_selector "path[clip-path*='-clip-before']", visible: :all, count: 1
      assert_selector "path[clip-path*='-clip-after']", visible: :all, count: 1
    end
  end
end
