require "test_helper"

class Budget::CreditEnvelopeSurfaceTriggerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @budget = budgets(:one)
    @family = @budget.family
    @rich = budget_category("Trigger rich")
    @spent_on_card = budget_category("Trigger card spending")
    @rich.update!(budgeted_spending: 200)
    # Deliberately under-funded: 40 allocated, 60 spent on the card, so the
    # payment envelope currently holds 40 and an allocation change to THIS
    # envelope must move it (that is what makes the assertions real).
    @spent_on_card.update!(budgeted_spending: 40)

    @card = @family.accounts.create!(
      accountable: CreditCard.new, name: "Trigger card",
      currency: "USD", balance: 0, status: "active"
    )
    create_transaction(account: @card, date: @budget.start_date, amount: 60,
                       category: @spent_on_card.category)
    Budget::Recalculate.call(family: @family, budget: @budget)
    assert_equal 40, credit_envelope.funded_amount.to_d, "setup must start under-funded"
  end

  test "POST /envelopes/cover recomputes the card's payment envelope without a page bootstrap" do
    assert_changes -> { credit_envelope.reload.funded_amount }, from: 40.to_d, to: 60.to_d do
      post cover_envelopes_path,
           params: { from_id: @rich.id, to_id: @spent_on_card.id,
                     budget_category_move: { amount: 30 } },
           as: :turbo_stream
    end

    assert_response :success
  end

  test "PATCH /api/v1/envelopes/:id recomputes the card's payment envelope without a page bootstrap" do
    api_key = ApiKey.create!(
      user: users(:family_admin), name: "Envelope trigger key",
      scopes: [ "read_write" ], source: "web",
      display_key: "env_trigger_#{SecureRandom.hex(8)}"
    )

    assert_changes -> { credit_envelope.reload.funded_amount }, from: 40.to_d, to: 60.to_d do
      # M4a's Api::V1::EnvelopesController#update requires params.require(:envelope) (Ruling P-m4b-1, 2026-10-10 pre-flight).
      patch api_v1_envelope_url(@spent_on_card.id),
            params: { envelope: { budgeted_spending: 100 } },
            headers: api_headers(api_key), as: :json
    end

    assert_response :success
  end

  private
    def budget_category(name)
      @budget.budget_categories.create!(
        category: @family.categories.create!(name: name, color: "#6172F3"),
        budgeted_spending: 0, currency: "USD"
      )
    end

    def credit_envelope
      CreditEnvelope.find_by!(budget: @budget, account: @card)
    end
end
