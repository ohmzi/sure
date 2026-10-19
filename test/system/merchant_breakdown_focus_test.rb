require "application_system_test_case"

# The owner (2026-10-18): picking a merchant on the merchants donut shows its
# latest transactions under the ring, with a way to all of them in Activity,
# and "All merchants" brings the list back.
class MerchantBreakdownFocusTest < ApplicationSystemTestCase
  include EntriesTestHelper

  test "a picked merchant's transactions replace the list until reset" do
    family = users(:family_admin).family
    shopping = family.categories.find_or_create_by!(name: "Shopping")
    amazon = family.merchants.find_or_create_by!(name: "Amazon") { |merchant| merchant.type = "FamilyMerchant" }
    7.times do |i|
      create_transaction(account: accounts(:depository), amount: 20 + i, name: "Amazon order #{i}",
                         category: shopping, merchant: amazon, date: Date.current - i.days)
    end
    create_transaction(account: accounts(:depository), amount: 15, name: "Corner shop",
                       category: shopping, date: Date.current)

    sign_in users(:family_admin)
    visit root_path

    within "#merchant-breakdown-section" do
      find("select[name='category_id']").find("option", text: "Shopping").select_option
      assert_text "Corner shop"
      click_on_ring_slice

      assert_selector "[data-merchant-preview-row]", count: 5
      assert_no_text "Corner shop"
      assert_link I18n.t("pages.dashboard.merchant_transactions.see_all", count: 7)

      click_on I18n.t("pages.dashboard.merchant_breakdown.show_all_merchants")
      assert_text "Corner shop"
      assert_no_selector "[data-merchant-preview-row]"
    end
  end

  test "picking the picked merchant again lets it go" do
    family = users(:family_admin).family
    shopping = family.categories.find_or_create_by!(name: "Shopping")
    create_transaction(account: accounts(:depository), amount: 20, name: "Corner shop", category: shopping, date: Date.current)

    sign_in users(:family_admin)
    visit root_path

    within "#merchant-breakdown-section" do
      find("select[name='category_id']").find("option", text: "Shopping").select_option
      assert_text "Corner shop"
      click_on_ring_slice
      assert_selector "[data-merchant-preview-row]"
      click_on_ring_slice
      assert_no_selector "[data-merchant-preview-row]"
      assert_selector "[data-breakdown-focus-target='list']", visible: true
    end
  end

  # The owner (2026-10-18): a finger run round the ring updates it live, and
  # lifting picks the merchant under it.
  test "a finger slid round the ring follows each merchant and picks the last" do
    family = users(:family_admin).family
    shopping = family.categories.find_or_create_by!(name: "Shopping")
    { "Amazon" => 60, "Corner Store" => 30, "Bookshop" => 10 }.each do |name, amount|
      merchant = family.merchants.find_or_create_by!(name: name) { |m| m.type = "FamilyMerchant" }
      create_transaction(account: accounts(:depository), amount: amount, name: "#{name} buy",
                         category: shopping, merchant: merchant, date: Date.current)
    end

    browser = page.driver.browser
    browser.manage.window.resize_to(390, 844)
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    sign_in users(:family_admin)
    visit root_path

    within "#merchant-breakdown-section" do
      find("select[name='category_id']").find("option", text: "Shopping").select_option
      assert_text "Bookshop"
    end
    ring = page.evaluate_script(<<~JS)
      (() => { const svg = document.querySelector("#merchant-breakdown-section [data-donut-chart-target=chartContainer] svg");
               svg.scrollIntoView({ block: "center" });
               const r = svg.getBoundingClientRect();
               return { x: r.left + r.width / 2, y: r.top + r.height / 2, r: Math.min(r.width, r.height) / 2 * 0.95 }; })()
    JS
    on_ring = ->(degrees) do
      radians = degrees * Math::PI / 180
      { x: ring["x"] + ring["r"] * Math.sin(radians), y: ring["y"] - ring["r"] * Math.cos(radians) }
    end
    middle = -> { page.evaluate_script(<<~JS) }
      [...document.querySelectorAll("#merchant-breakdown-section [data-donut-chart-target=contentContainer] > div")].find(e => !e.classList.contains("hidden")).innerText
    JS

    touch("touchStart", on_ring.(30))   # Amazon: the first 60% of the ring
    seen = [ middle.() ]
    [ 120, 200, 250, 300, 340 ].each do |degrees|
      touch("touchMove", on_ring.(degrees))
      sleep 0.05
      seen << middle.()
    end
    touch("touchEnd")

    assert seen.first.include?("Amazon"), seen.inspect
    assert seen.any? { |text| text.include?("Corner Store") }, seen.inspect
    assert seen.last.include?("Bookshop"), seen.inspect
    within("#merchant-breakdown-section") { assert_selector "[data-merchant-preview-row]", text: "Bookshop buy" }
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  # Card charges (the owner, 2026-10-18): a category picked on the ring or in
  # the list previews its charges instead of leaving for Activity.
  test "card charges preview a category picked on the ring or in the list" do
    travel = users(:family_admin).family.categories.find_or_create_by!(name: "Travel")
    create_transaction(account: accounts(:credit_card), amount: 300, name: "Flight", category: travel, date: Date.current)
    sign_in users(:family_admin)
    visit root_path

    within "#outflows-donut-section" do
      click_on_ring_slice("#outflows-donut-section")
      assert_selector "[data-merchant-preview-row]", minimum: 1
      click_on I18n.t("pages.dashboard.outflows_donut.show_all_categories")
      assert_no_selector "[data-merchant-preview-row]"

      find("[data-breakdown-focus-target='list'] a[data-preview-url]", match: :first).click
      assert_selector "[data-merchant-preview-row]", minimum: 1
    end
    assert_current_path root_path
  end

  private
    def touch(type, point = nil)
      points = point ? [ point ] : []
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: type, touchPoints: points)
    end

    # The middle of a slice's box is the ring's centre, under the amount, so
    # click a point on the slice's own outline instead.
    def click_on_ring_slice(section = "#merchant-breakdown-section")
      assert_selector "path.hover-path[data-segment-id]", visible: :all
      point = page.evaluate_script(<<~JS)
        (() => {
          const path = document.querySelector("#{section} path.hover-path[data-segment-id]");
          path.scrollIntoView({ block: "center" });
          const p = path.getPointAtLength(path.getTotalLength() * 0.1);
          const m = path.getScreenCTM();
          return { x: Math.round(p.x * m.a + p.y * m.c + m.e), y: Math.round(p.x * m.b + p.y * m.d + m.f) };
        })()
      JS
      page.driver.browser.action.move_to_location(point["x"], point["y"]).click.perform
    end
end
