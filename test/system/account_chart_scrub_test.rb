require "application_system_test_case"

# The owner's ask (2026-10-18): hold a finger on an account's chart and slide it
# sideways, and the balance above follows the point under the finger, the way a
# stock app does. A phone hands a sideways drag to the page unless the chart's
# box says otherwise, which cancels the scrub after the first step.
class AccountChartScrubTest < ApplicationSystemTestCase
  PHONE = [ 390, 844 ].freeze

  setup do
    browser = page.driver.browser
    browser.manage.window.resize_to(*PHONE)
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: PHONE[0], height: PHONE[1], deviceScaleFactor: 1, mobile: true)
    browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "a finger dragged sideways along the chart keeps moving the headline balance" do
    sign_in users(:family_admin)
    visit account_url(accounts(:credit_card))

    assert_selector "#lineChart svg"
    page.execute_script("document.getElementById('lineChart').scrollIntoView({ block: 'center' })")
    sleep 0.3

    box = page.evaluate_script(<<~JS)
      (() => { const r = document.getElementById('lineChart').getBoundingClientRect();
               return { left: r.left, right: r.right, y: r.top + r.height / 2 }; })()
    JS
    label = find("[data-scrub-readout-target='label']")
    resting = label.text

    touch("touchStart", box["left"] + 10, box["y"])
    readings = []
    10.times do |step|
      touch("touchMove", box["left"] + 10 + (step + 1) * (box["right"] - box["left"] - 20) / 10.0, box["y"])
      sleep 0.05
      readings << label.text
    end
    touch("touchEnd")

    assert_not_equal resting, readings.last, "the label should follow the finger to the far end of the chart"
    assert_operator readings.uniq.size, :>, 2, "the label should change as the finger moves, got #{readings.uniq.inspect}"
  end

  private
    def touch(type, x = nil, y = nil)
      points = x ? [ { x: x, y: y } ] : []
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: type, touchPoints: points)
    end
end
