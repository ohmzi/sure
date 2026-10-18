require "test_helper"

# The bill drawer's payment history line (the animation pass, 2026-10-18): it
# draws itself in, its dots pop in one after another, and each dot names its
# month and amount when pointed at.
class DS::SparklineTest < ViewComponent::TestCase
  SERIES = [ [ Date.new(2026, 8, 1), 120 ], [ Date.new(2026, 9, 1), 0 ], [ Date.new(2026, 10, 1), 137.71 ] ].freeze

  test "the line draws in and every dot reads its month and amount" do
    render_inline(DS::Sparkline.new(series: SERIES, aria_label: "History", currency: "CAD"))

    assert_selector "polyline.draw-line[pathlength='1600']"
    assert_selector "circle.pop-in", count: 3
    assert_selector "circle title", text: /Oct 2026/
    assert_selector "circle title", text: /137\.71/
  end

  test "without a currency a dot still reads its number" do
    render_inline(DS::Sparkline.new(series: SERIES, aria_label: "History"))

    assert_selector "circle title", text: /120/
  end
end
