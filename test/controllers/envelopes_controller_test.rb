require "test_helper"

class EnvelopesControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @budget = budgets(:one)
    @family = @budget.family
    @donor = budget_category("Donor")
    @red = budget_category("Red")
  end

  test "cover moves money from the donor into the red envelope through move_allocation!" do
    @donor.update!(budgeted_spending: 200)
    @red.update!(budgeted_spending: -40)

    assert_difference -> { @donor.reload.budgeted_spending } => -40,
                      -> { @red.reload.budgeted_spending } => 40 do
      post cover_envelopes_path,
           params: { from_id: @donor.id, to_id: @red.id,
                     budget_category_move: { amount: 40 } },
           as: :turbo_stream
    end

    assert_response :success
  end

  test "cover refuses a donor without funds" do
    @donor.update!(budgeted_spending: 10)
    @red.update!(budgeted_spending: -40)

    post cover_envelopes_path,
         params: { from_id: @donor.id, to_id: @red.id,
                   budget_category_move: { amount: 40 } },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal 10, @donor.reload.budgeted_spending
    assert_equal(-40, @red.reload.budgeted_spending)
  end

  test "move is the same gesture and reuses cover's stream" do
    @donor.update!(budgeted_spending: 200)
    @red.update!(budgeted_spending: 0)

    post move_envelopes_path,
         params: { from_id: @donor.id, to_id: @red.id,
                   budget_category_move: { amount: 60 } },
         as: :turbo_stream

    assert_response :success
    assert_equal 140, @donor.reload.budgeted_spending
    assert_equal 60, @red.reload.budgeted_spending
  end

  test "a gesture resolves the month it was issued from" do
    next_month = Budget.find_or_bootstrap(@family, start_date: 1.month.from_now)
    donor = budget_category("Next donor", budget: next_month)
    red = budget_category("Next red", budget: next_month)
    donor.update!(budgeted_spending: 200)
    red.update!(budgeted_spending: 0)

    post cover_envelopes_path,
         params: { month_year: next_month.to_param, from_id: donor.id, to_id: red.id,
                   budget_category_move: { amount: 40 } },
         as: :turbo_stream

    assert_response :success
    assert_equal 160, donor.reload.budgeted_spending
    assert_equal 40, red.reload.budgeted_spending
  end

  test "show renders the YNAB surface with the ready-to-assign banner" do
    get envelope_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "[data-controller~='envelope']"
    assert_select "[data-envelope-target='banner']"
    assert_match I18n.t("envelopes.ready_to_assign.heading"), response.body
  end

  test "show keeps the copy-previous prompt for an uninitialized month" do
    future = Budget.date_to_param(1.month.from_now)
    get envelope_url(future)

    assert_response :success
    assert_match I18n.t("budgets.copy_previous_prompt.title"), response.body
  end

  test "the ready-to-assign banner is red when the pool is negative" do
    # Assign far past any fixture income so RTA is unambiguously negative.
    @red.update!(budgeted_spending: 1_000_000)
    @budget.sync_budgeted_spending!

    get envelope_url(@budget.to_param)

    assert_select "[data-envelope-target='banner'] .text-destructive", minimum: 1
  end

  test "show renders expected_income beside the ready-to-assign pool" do
    @budget.update!(expected_income: 7_000)

    get envelope_url(@budget.to_param)

    assert_select "[data-envelope-target='expected-income']", minimum: 1
    assert_match "7,000", response.body
  end

  test "update persists expected_income for the month" do
    patch envelope_url(@budget.to_param), params: { budget: { expected_income: "8000" } }

    assert_redirected_to envelope_path(@budget.to_param)
    assert_equal 8_000, @budget.reload.expected_income
  end

  test "assign updates the envelope and re-renders its row over turbo" do
    post assign_envelopes_path,
         params: { month_year: @budget.to_param, id: @donor.id,
                   budget_category: { budgeted_spending: "250" } },
         as: :turbo_stream

    assert_response :success
    assert_equal 250, @donor.reload.budgeted_spending
    assert_match dom_id(@donor, :envelope), response.body
  end

  test "the surface ships the move dialog with the budget-move targets" do
    get envelope_url(@budget.to_param)

    assert_select "[data-controller~='budget-move']"
    assert_select "select[name='to_id'][data-budget-move-target='toSelect']"
    assert_select "input[name='from_id'][data-budget-move-target='fromId']"
    assert_select "input[name='month_year']"
  end

  test "breadcrumbs include the Plan hub for preview users" do
    users(:family_admin).update!(preferences: (users(:family_admin).preferences || {}).merge("preview_features_enabled" => true))

    get envelope_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, minimum: 1
  end

  test "renders no Plan links without preview features" do
    get envelope_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, count: 0
    assert_select "a[href=?]", budgets_path, minimum: 1
  end

  test "the envelope surface renders the credit-card payments group" do
    card = @family.accounts.create!(
      accountable: CreditCard.new, name: "Rewards", currency: @budget.currency,
      balance: 250, status: "active"
    )
    CreditEnvelope.create!(
      budget: @budget, account: card, funded_amount: 60, payment_amount: 20, currency: @budget.currency
    )

    get envelope_url(@budget.to_param)

    assert_response :success
    assert_select "[data-testid='credit-card-payments']"
    assert_match I18n.t("budgets.credit_card_payments.title"), response.body
  end

  private
    def budget_category(name, budget: @budget)
      category = @family.categories.create!(name: "#{name} #{SecureRandom.hex(4)}", color: "#6172F3")
      budget.budget_categories.create!(category: category, budgeted_spending: 0, currency: "USD")
    end
end
