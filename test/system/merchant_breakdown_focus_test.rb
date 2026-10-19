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
