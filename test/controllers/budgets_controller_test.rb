require "test_helper"

class BudgetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "index redirects to the current month budget" do
    get budgets_url

    assert_redirected_to envelope_path(Budget.date_to_param(Date.current))
  end

  test "legacy /budgets/:month redirects to the envelope surface" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_redirected_to envelope_path(Budget.date_to_param(Date.current))
  end
end

class BudgetsControllerSharingTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:empty)
    @family.update!(personal_budgets: true)
    @owner = users(:josh)
    @viewer = users(:ann)
    @date = Date.current.beginning_of_month
  end

  test "household budget is viewable and editable by any family member" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner, household: true)
    sign_in @viewer

    get envelope_url(Budget.date_to_param(@date), params: { owner: "household" })
    assert_response :success

    patch budget_url(Budget.date_to_param(@date), params: { owner: "household" }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }
    assert_response :redirect
  end

  test "household tab is unreachable once household_budget_enabled is off, falling back to the viewer's own budget" do
    @family.update!(household_budget_enabled: false)
    sign_in @viewer

    get envelope_url(Budget.date_to_param(@date), params: { owner: "household" })

    assert_response :success
    assert_equal @viewer.id, Budget.find_by(family: @family, start_date: @date).user_id
  end

  test "a member without a BudgetShare cannot view another member's personal budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    sign_in @viewer

    get envelope_url(Budget.date_to_param(@date), params: { owner: @owner.id })

    # Falls back to the viewer's own budget rather than the owner's.
    assert_response :success
    assert Budget.exists?(family: @family, start_date: @date, user_id: @viewer.id)
  end

  test "a read_only BudgetShare lets the viewer see but not edit the owner's budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")
    sign_in @viewer

    get envelope_url(Budget.date_to_param(@date), params: { owner: @owner.id })
    assert_response :success

    get edit_budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })
    assert_response :not_found

    patch budget_url(Budget.date_to_param(@date), params: { owner: @owner.id }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }
    assert_response :not_found
  end

  test "a read_write BudgetShare lets the viewer edit the owner's budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_write")
    sign_in @viewer

    patch budget_url(Budget.date_to_param(@date), params: { owner: @owner.id }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }

    assert_redirected_to budget_budget_categories_url(Budget.date_to_param(@date), owner: @owner.id)
    assert_equal 1000, Budget.find_by(family: @family, user: @owner).budgeted_spending.to_i
  end
end
