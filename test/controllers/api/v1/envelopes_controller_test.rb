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

  test "401s without credentials" do
    get api_v1_envelopes_url, as: :json

    assert_response :unauthorized
  end

  # The API key scope is not the only gate: a member granted read_only on the
  # owner's personal budget must not write through the API either. 404, like
  # the web surface's ensure_budget_editable! (Ruling M4a-L3).
  test "a read_only viewer cannot write through the API" do
    viewer = users(:family_member)
    viewer.api_keys.active.destroy_all
    viewer_key = ApiKey.create!(user: viewer, name: "Viewer", scopes: [ "read_write" ],
                                source: "web", display_key: "test_viewer_#{SecureRandom.hex(8)}")
    owned_budget = @family.budgets.create!(
      start_date: 7.months.ago.beginning_of_month, end_date: 7.months.ago.end_of_month,
      budgeted_spending: 1000, currency: "USD", user: @user
    )
    owned_envelope = owned_budget.budget_categories.create!(
      category: categories(:food_and_drink), budgeted_spending: 300, currency: "USD"
    )
    BudgetShare.create!(owner: @user, viewer: viewer, permission: "read_only")

    patch api_v1_envelope_url(owned_envelope.id),
          params: { envelope: { budgeted_spending: "450" } },
          headers: api_headers(viewer_key), as: :json
    assert_response :not_found
    assert_equal 300, owned_envelope.reload.budgeted_spending

    delete api_v1_envelope_url(owned_envelope.id), headers: api_headers(viewer_key), as: :json
    assert_response :not_found
    assert BudgetCategory.exists?(owned_envelope.id)
  end

  # Invalid target params must answer with the API's JSON 422 contract rather
  # than the framework error page (docs/llm-guides/api-endpoint-consistency.md
  # requires the 422 case; the web sibling rescues the same error).
  test "rejects an invalid target with a JSON 422" do
    patch api_v1_envelope_url(@envelope.id),
          params: { envelope: { target_type: "bogus", target_amount: "10" } },
          headers: api_headers(@write_key), as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_nil @envelope.reload.target_type
  end

  # A combined payload (money + an invalid target) must be all-or-nothing: the
  # rejected request must not leave the money write committed without the
  # mandated Recalculate/sync_budgeted_spending! (Ruling M4a-L3).
  test "an invalid target rolls back a money write in the same payload" do
    patch api_v1_envelope_url(@envelope.id),
          params: { envelope: { budgeted_spending: "450", target_type: "bogus", target_amount: "10" } },
          headers: api_headers(@write_key), as: :json

    assert_response :unprocessable_entity
    assert_equal 300, @envelope.reload.budgeted_spending
  end

  # `rollover_enabled: false` is a legitimate value: the guard must be key
  # presence, not truthiness (Ruling M4a-L3).
  test "turns rollover off and propagates the choice forward" do
    @envelope.update!(rollover_enabled: true)
    later_budget = @family.budgets.create!(
      start_date: 4.months.ago.beginning_of_month, end_date: 4.months.ago.end_of_month,
      budgeted_spending: 1000, currency: "USD"
    )
    later_envelope = later_budget.budget_categories.create!(
      category: categories(:food_and_drink), budgeted_spending: 300, currency: "USD", rollover_enabled: true
    )

    patch api_v1_envelope_url(@envelope.id),
          params: { envelope: { rollover_enabled: false } },
          headers: api_headers(@write_key), as: :json

    assert_response :success
    assert_equal false, @envelope.reload.rollover_enabled
    assert_equal false, later_envelope.reload.rollover_enabled
  end

  # The API reads the materialized column straight, so without the refresh it
  # can serve a carry left stale by a sync or a recategorisation (Ruling
  # M4a-L3; same test shape as the sibling budget-categories API). The refresh
  # must be declared BEFORE the loader, or show renders the pre-refresh row
  # (Ruling M4a-L3b); the served-payload assertion below is what catches it.
  test "show refreshes a stale materialized carry rather than serving it" do
    earlier = Budget.find_or_bootstrap(@family, start_date: 3.months.ago.to_date, user: nil)
    earlier.update!(budgeted_spending: 3000, expected_income: 5000)
    earlier.budget_categories.find_by!(category: categories(:food_and_drink))
           .update!(budgeted_spending: 500, rollover_enabled: true)

    later = Budget.find_or_bootstrap(@family, start_date: 2.months.ago.to_date, user: nil)
    later.update!(budgeted_spending: 3000, expected_income: 5000)
    later_envelope = later.budget_categories.find_by!(category: categories(:food_and_drink))
    later_envelope.update!(budgeted_spending: 500, rollover_enabled: true)

    # Simulate what a sync does: rewrite the stored carry behind the app's
    # back, the way a changed past month would leave it.
    later_envelope.update_column(:rolled_over_amount, 0)

    get api_v1_envelope_url(later_envelope.id), headers: api_headers(@write_key), as: :json

    assert_response :success
    assert_equal 500, later_envelope.reload[:rolled_over_amount]
    body = JSON.parse(response.body)
    assert_equal "$500.00", body["rolled_over_amount"]
  end
end
