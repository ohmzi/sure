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

  private
    def budget_category(name, budget: @budget)
      category = @family.categories.create!(name: "#{name} #{SecureRandom.hex(4)}", color: "#6172F3")
      budget.budget_categories.create!(category: category, budgeted_spending: 0, currency: "USD")
    end
end
