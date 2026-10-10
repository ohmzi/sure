require "test_helper"

class Budget::CreditEnvelopeTriggerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @category = @family.categories.create!(name: "Groceries")
    @card = @family.accounts.create!(
      accountable: CreditCard.new, name: "Rewards", currency: "USD", balance: 0, status: "active"
    )
    @checking = @family.accounts.create!(
      accountable: Depository.new, name: "Checking", currency: "USD", balance: 10_000, status: "active"
    )
  end

  test "bootstrapping a budget recomputes its credit envelopes" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 5_000)
    budget.budget_categories.find_by!(category: @category).update!(budgeted_spending: 100)
    create_transaction(account: @card, date: budget.start_date, amount: 60, category: @category)

    # A later bootstrap is what every surface does on the way in.
    Budget.find_or_bootstrap(@family, start_date: Date.current)

    envelope = CreditEnvelope.find_by!(budget_id: budget.id, account_id: @card.id)
    assert_equal 60, envelope.funded_amount.to_d
  end

  test "the seam takes the rollover chain lock before the credit chain lock" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 5_000)
    # Rollover on, so its calculator takes its lock too and both locks appear.
    budget.budget_categories.find_by!(category: @category)
          .update!(budgeted_spending: 100, rollover_enabled: true)

    sql = capture_sql { Budget.find_or_bootstrap(@family, start_date: Date.current) }

    rollover = sql.index { |s| s.include?("pg_advisory_xact_lock") && s.include?("1920231276") }
    credit   = sql.index { |s| s.include?("pg_advisory_xact_lock") && s.include?("1920231277") }

    assert rollover, "the rollover chain must take its lock on bootstrap"
    assert credit, "the credit chain must take its lock on bootstrap"
    assert_operator rollover, :<, credit, "the seam must lock rollover before credit"
  end

  test "copy_from! recomputes the target month's credit envelopes" do
    source = initialized_budget(2.months.ago)
    allocate(source, 100)
    create_transaction(account: @card, date: source.start_date, amount: 60, category: @category)

    target = initialized_budget(1.month.ago)
    # Drop the row so we can prove copy_from! itself (re)creates it.
    CreditEnvelope.where(budget_id: target.id).delete_all

    target.copy_from!(source)

    envelope = CreditEnvelope.find_by!(budget_id: target.id, account_id: @card.id)
    assert_equal 60, envelope.funded_amount.to_d
  end

  test "an entry write never touches credit_envelopes (D8)" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    Budget::CreditEnvelopeCalculator.new(family: @family, budget: budget).recompute!
    before = CreditEnvelope.where(budget_id: budget.id).order(:account_id).pluck(:account_id, :funded_amount, :payment_amount)

    writes = capture_sql do
      create_transaction(account: @card, date: budget.start_date, amount: 60, category: @category)
    end.select { |sql| sql.include?('"credit_envelopes"') }

    assert_empty writes, "an entry writer must never write the derived rows"
    after = CreditEnvelope.where(budget_id: budget.id).order(:account_id).pluck(:account_id, :funded_amount, :payment_amount)
    assert_equal before, after
  end

  private
    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        payload = args.last
        statements << payload[:sql] unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def initialized_budget(date)
      Budget.find_or_bootstrap(@family, start_date: date).tap do |budget|
        budget.update!(budgeted_spending: 5_000, expected_income: 7_000)
      end
    end

    def allocate(budget, amount)
      budget.budget_categories.find_by!(category: @category)
            .update!(budgeted_spending: amount, rollover_enabled: false)
    end
end
