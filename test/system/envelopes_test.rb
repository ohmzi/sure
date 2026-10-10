require "application_system_test_case"

class EnvelopesTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @budget = Budget.find_or_bootstrap(users(:family_admin).family, start_date: Date.current)
  end

  test "assign to an envelope from the surface" do
    visit envelope_url(Budget.date_to_param(Date.current))

    within "[data-controller~='envelope']" do
      assert_selector "[data-envelope-target='banner']"
    end

    # Submit the first envelope's inline assign field; the row is replaced over
    # Turbo, so its assigned figure must reflect the value (Enter is wired to
    # envelope#submit by the field's data-action).
    first_field = first("input[name='budget_category[budgeted_spending]']")
    first_field.fill_in with: "100"
    first_field.send_keys(:enter)

    assert_selector "input[name='budget_category[budgeted_spending]'][value^='100']"
  end
end
