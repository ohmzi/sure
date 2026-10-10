# frozen_string_literal: true

require "test_helper"

class Api::V1::EnvelopesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @write_key = ApiKey.create!(user: @user, name: "Write", scopes: [ "read_write" ],
                                source: "web", display_key: "test_write_#{SecureRandom.hex(8)}")
    @read_key = ApiKey.create!(user: @user, name: "Read", scopes: [ "read" ],
                               source: "web", display_key: "test_read_#{SecureRandom.hex(8)}")

    # A non-current month: budgets(:one) is dylan_family/current-month/user-NULL,
    # and Budget validates start_date/end_date uniqueness scoped to
    # family_id + user_id, so creating a current-month row here would raise
    # RecordInvalid in setup. 5.months.ago matches the sibling API tests.
    @budget = @family.budgets.create!(
      start_date: 5.months.ago.beginning_of_month, end_date: 5.months.ago.end_of_month,
      budgeted_spending: 1000, currency: "USD"
    )
    @envelope = @budget.budget_categories.create!(
      category: categories(:food_and_drink), budgeted_spending: 300, currency: "USD"
    )
  end

  test "patches an envelope allocation" do
    patch api_v1_envelope_url(@envelope.id),
          params: { envelope: { budgeted_spending: "450" } },
          headers: api_headers(@write_key), as: :json

    assert_response :success
    assert_equal 450, @envelope.reload.budgeted_spending
  end

  test "deletes an envelope" do
    assert_difference "BudgetCategory.count", -1 do
      delete api_v1_envelope_url(@envelope.id), headers: api_headers(@write_key), as: :json
    end
    assert_response :success
  end

  test "rejects a write with only read scope" do
    patch api_v1_envelope_url(@envelope.id),
          params: { envelope: { budgeted_spending: "450" } },
          headers: api_headers(@read_key), as: :json

    assert_response :forbidden
    assert_equal 300, @envelope.reload.budgeted_spending
  end

  test "lists envelopes scoped to the family" do
    get api_v1_envelopes_url, headers: api_headers(@write_key), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body["envelopes"].map { |envelope| envelope["id"] }, @envelope.id
  end

  test "shows one envelope with its target fields" do
    @envelope.update!(target_type: "savings_balance", target_amount: 900)

    get api_v1_envelope_url(@envelope.id), headers: api_headers(@write_key), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "savings_balance", body["target_type"]
    assert_equal 900, body["target_amount"].to_f
  end

  test "404s an unknown envelope id" do
    get api_v1_envelope_url(SecureRandom.uuid), headers: api_headers(@write_key), as: :json

    assert_response :not_found
  end
end
