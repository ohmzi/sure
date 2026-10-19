require "application_system_test_case"

# The owner's ask (2026-10-18): on Home, a finger slid sideways along the net
# worth, spending and money in/out charts moves the figures above them to the
# point under it, the way a stock app does, and lifting it puts them back.
class DashboardChartScrubTest < ApplicationSystemTestCase
  PHONE = [ 390, 844 ].freeze

  setup do
    browser = page.driver.browser
    browser.manage.window.resize_to(*PHONE)
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: PHONE[0], height: PHONE[1], deviceScaleFactor: 1, mobile: true)
    browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    sign_in users(:family_admin)
    visit root_path
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "the net worth figure follows a finger along its chart" do
    assert_scrubs "#net-worth-chart", "#netWorthChart"
  end

  test "the spending figures follow a finger along the month" do
    assert_scrubs "#spending-trend-section", "[data-controller~='spending-chart']"
  end

  test "the money in and out summary follows a finger across the months" do
    assert_scrubs "#money-flow-section", "[data-controller~='bar-chart']", from: 0.05, to: 0.5
  end

  # Press and hold, cleaned up (the owner, 2026-10-18): a swipe up the page
  # that starts on a chart is a scroll, and flashes no reading.
  test "a vertical swipe starting on a chart leaves the figures alone" do
    chart = "[data-controller~='bar-chart']"
    assert_selector "#{chart} svg"
    page.execute_script("document.querySelector(#{chart.to_json}).scrollIntoView({ block: 'center' })")
    sleep 0.3
    label = find("#money-flow-section [data-scrub-readout-target='label']")
    resting = label.text
    box = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(#{chart.to_json}).getBoundingClientRect();
               return { x: r.left + r.width * 0.2, y: r.top + r.height / 2 }; })()
    JS

    seen = []
    touch("touchStart", box["x"], box["y"])
    seen << label.text
    4.times do |step|
      touch("touchMove", box["x"], box["y"] - (step + 1) * 12)
      seen << label.text
    end
    touch("touchEnd")

    assert_equal [ resting ], seen.uniq
  end

  private
    def assert_scrubs(section, chart, from: 0.05, to: 0.95)
      assert_selector "#{chart} svg"
      page.execute_script("document.querySelector(#{chart.to_json}).scrollIntoView({ block: 'center' })")
      sleep 0.3
      label = find("#{section} [data-scrub-readout-target='label']")
      resting = label.text
      box = page.evaluate_script(<<~JS)
        (() => { const r = document.querySelector(#{chart.to_json}).getBoundingClientRect();
                 return { left: r.left, width: r.width, y: r.top + r.height / 2 }; })()
      JS
      at = ->(fraction) { box["left"] + box["width"] * fraction }

      touch("touchStart", at.(from), box["y"])
      readings = 8.times.map do |step|
        touch("touchMove", at.(from + (to - from) * (step + 1) / 8.0), box["y"])
        sleep 0.05
        label.text
      end

      assert_not_equal resting, readings.last, "the label should follow the finger"
      touch("touchEnd")
      assert_selector "#{section} [data-scrub-readout-target='label']", exact_text: resting
    end

    def touch(type, x = nil, y = nil)
      points = x ? [ { x: x, y: y } ] : []
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: type, touchPoints: points)
    end
end
