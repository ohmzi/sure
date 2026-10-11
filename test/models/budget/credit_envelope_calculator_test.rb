require "test_helper"

class Budget::CreditEnvelopeCalculatorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @category = @family.categories.create!(name: "Groceries", color: "#6172F3")
    @parent_category = @family.categories.create!(name: "Home", color: "#6172F3")
    @ring_fenced_child = @family.categories.create!(name: "Renovations", parent: @parent_category, color: "#6172F3")
    @card = create_card(name: "Rewards")
    @checking = create_checking
  end

  test "card spending funded from an envelope funds that card's payment envelope" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)

    recompute!(budget)

    envelope = envelope_for(budget, @card)
    assert_equal 60, envelope.funded_amount.to_d
    assert_equal 0, envelope.payment_amount.to_d
    assert_equal 60, envelope.payment_available.to_d
  end

  test "a cc payment transfer reduces the payment envelope" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)

    pay(budget, amount: 60)

    recompute!(budget)

    envelope = envelope_for(budget, @card)
    assert_equal 60, envelope.funded_amount.to_d
    assert_equal 60, envelope.payment_amount.to_d
    assert_equal 0, envelope.payment_available.to_d
  end

  test "credit overspending increases card debt but not the payment envelope" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    # Cash exhausts the envelope first, then the card purchase has nothing to draw on.
    spend(budget, amount: 100, account: @checking, category: @category)
    spend(budget, amount: 60, account: @card, category: @category)

    recompute!(budget)

    assert_equal 0, envelope_for(budget, @card).funded_amount.to_d,
      "no envelope money was left to move onto the card; the debt grew instead"
  end

  test "a card purchase larger than its envelope is funded only up to the envelope" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 130, account: @card, category: @category)

    recompute!(budget)

    assert_equal 100, envelope_for(budget, @card).funded_amount.to_d
  end

  # Ruling M4-L3 (2026-10-10 close-out): a card refund is a negative entry on
  # the card; it must reduce what the envelope set aside, not vanish. The old
  # positive-only query kept the full purchase funded and overstated the
  # payment envelope.
  test "a card refund reduces the funded amount" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)
    create_transaction(account: @card, date: budget.start_date, amount: -20, category: @category)

    recompute!(budget)

    envelope = envelope_for(budget, @card)
    assert_equal 40, envelope.funded_amount.to_d
    assert_equal 40, envelope.payment_available.to_d
  end

  # Ruling M4-L3 (2026-10-10 close-out): netted at the envelope's per-card
  # level and floored at zero -- a refund larger than the spending must never
  # produce a negative envelope (or negative funding for the card).
  test "a refund larger than the card spending floors at zero" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)
    create_transaction(account: @card, date: budget.start_date, amount: -80, category: @category)

    recompute!(budget)

    envelope = envelope_for(budget, @card)
    assert_equal 0, envelope.funded_amount.to_d
    assert_equal 0, envelope.payment_available.to_d
  end

  test "a ring-fenced child's allocation is not also fundable from the parent (Ruling M4b-L4)" do
    # The parent's stored budgeted_spending is the GROUP total (500 = 300 own +
    # 200 child). Using it raw would let the child's 200 fund cards from BOTH
    # envelopes, so the month's 500 assignments could fund 700 of card spending.
    budget = initialized_budget(Date.current)
    parent_bc = budget.budget_categories.find_by!(category: @parent_category)
    child_bc  = budget.budget_categories.find_by!(category: @ring_fenced_child)
    child_bc.update!(budgeted_spending: 200)
    parent_bc.update!(budgeted_spending: 500)

    # 700 of card spending, all on the child's category.
    create_transaction(account: @card, date: budget.start_date, amount: 700, category: @ring_fenced_child)

    Budget::CreditEnvelopeCalculator.new(family: @family, budget: budget).recompute!

    # Only the child's own 200 is spendable for it; the parent's envelope holds
    # its own 300 and must not fund the child's spending.
    assert_equal 200, envelope_for(budget, @card).funded_amount.to_d
  end

  test "a ring-fenced child's allocation funds the card only once across both envelopes (Ruling M4b-L4)" do
    # The recorded probe case, scaled to this test's numbers: parent 500 =
    # 300 own + 200 ring-fenced child, then 700 of card spending split 500 on
    # the parent's category and 200 on the child's. The raw formula funded all
    # 700 (500 from the parent's inflated envelope, 200 from the child's) from
    # 500 assigned. Only the parent's own 300 may fund its spending, and the
    # child's 200 its own: 500, never 700.
    budget = initialized_budget(Date.current)
    parent_bc = budget.budget_categories.find_by!(category: @parent_category)
    child_bc  = budget.budget_categories.find_by!(category: @ring_fenced_child)
    child_bc.update!(budgeted_spending: 200)
    parent_bc.update!(budgeted_spending: 500)

    create_transaction(account: @card, date: budget.start_date, amount: 500, category: @parent_category)
    create_transaction(account: @card, date: budget.start_date, amount: 200, category: @ring_fenced_child)

    Budget::CreditEnvelopeCalculator.new(family: @family, budget: budget).recompute!

    assert_equal 500, envelope_for(budget, @card).funded_amount.to_d,
      "500 assigned cannot fund 700 of card spending"
  end

  test "two cards funded from one envelope stay separate and never double count" do
    second_card = create_card(name: "Travel")
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)
    spend(budget, amount: 60, account: second_card, category: @category)

    recompute!(budget)

    first = envelope_for(budget, @card)
    other = envelope_for(budget, second_card)

    # 100 shared across 120 spent: scaled onto each card's own 60.
    assert_in_delta 50.0, first.funded_amount.to_d, 0.01
    assert_in_delta 50.0, other.funded_amount.to_d, 0.01
    assert_in_delta 100.0, first.funded_amount.to_d + other.funded_amount.to_d, 0.01,
      "the envelope never funds more than it holds"
  end

  test "funding accumulates across the chain" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(first, amount: 40, account: @card, category: @category)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)
    spend(second, amount: 30, account: @card, category: @category)

    recompute!(second)

    assert_equal 40, envelope_for(first, @card).funded_amount.to_d
    assert_equal 70, envelope_for(second, @card).funded_amount.to_d
  end

  test "payments carry across the chain and draw the payment envelope down" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(first, amount: 40, account: @card, category: @category)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)
    pay(second, amount: 20)

    recompute!(second)

    row = envelope_for(second, @card)
    assert_equal 40, row.funded_amount.to_d
    assert_equal 20, row.payment_amount.to_d
    assert_equal 20, row.payment_available.to_d
  end

  test "recomputing twice writes nothing the second time" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)
    recompute!(budget)

    assert_empty credit_envelope_writes { recompute!(budget) },
      "a stable recompute must not churn the materialized rows"
  end

  test "a scaling remainder still settles after a second recompute" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    # 130 * (100/130) is a non-terminating decimal; only round(4) before the
    # compare makes the stored value equal to the next computed value.
    spend(budget, amount: 130, account: @card, category: @category)
    recompute!(budget)

    assert_empty credit_envelope_writes { recompute!(budget) }
    assert_equal 100, envelope_for(budget, @card).funded_amount.to_d
  end

  test "a missing exchange rate raises instead of converting at 1:1" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    create_transaction(account: @card, date: budget.start_date, amount: 60,
                       category: @category, currency: "EUR")

    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_raises(Budget::CreditEnvelopeCalculator::MissingExchangeRate) { recompute!(budget) }
  end

  test "a card-to-card transfer draws down only the receiving card's envelope" do
    # Card A pays card B: B received a payment; A's debt grew. Only the
    # negative (inflow) leg may count — see Task 1's direction characterization.
    # This test's budget is built here — it had no @budget (Ruling P-m4b-3, 2026-10-10 pre-flight).
    budget = initialized_budget(Date.current)
    card_b = @family.accounts.create!(
      accountable: CreditCard.new, name: "Card B",
      currency: "USD", balance: 0, status: "active"
    )
    Transfer::Creator.new(
      family: @family, source_account_id: @card.id, destination_account_id: card_b.id,
      date: budget.start_date, amount: 60
    ).create

    Budget::CreditEnvelopeCalculator.new(family: @family, budget: budget).recompute!

    assert_equal 60, envelope_for(budget, card_b).payment_amount.to_d
    assert_equal 0, envelope_for(budget, @card).payment_amount.to_d,
      "the paying card's debt grew; it received no payment"
  end

  test "an excluded cc_payment leg does not draw the payment envelope down" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)

    transfer = Transfer::Creator.new(
      family: @family,
      source_account_id: @checking.id,
      destination_account_id: @card.id,
      date: budget.start_date,
      amount: 30
    ).create
    transfer.inflow_transaction.entry.update!(excluded: true)

    recompute!(budget)

    row = envelope_for(budget, @card)
    assert_equal 60, row.funded_amount.to_d
    assert_equal 0, row.payment_amount.to_d
  end

  test "a card that leaves scope loses its envelope rows" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)
    recompute!(budget)
    assert CreditEnvelope.exists?(budget_id: budget.id, account_id: @card.id)

    @card.update!(status: "disabled")
    recompute!(budget)

    assert_not CreditEnvelope.exists?(budget_id: budget.id, account_id: @card.id)
  end

  test "the chain lock is taken before the derived rows are written" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    spend(budget, amount: 60, account: @card, category: @category)

    sql = capture_sql { recompute!(budget) }

    lock = sql.index { |statement| statement.include?("pg_advisory_xact_lock") }
    write = sql.index do |statement|
      statement.include?('"credit_envelopes"') && statement.match?(/\A\s*(INSERT|UPDATE)/)
    end

    assert lock, "the chain must be locked before its derived rows are written"
    assert write, "expected this recompute to write"
    assert_operator lock, :<, write, "the lock has to be taken before the read-then-write, not after"
  end

  test "household and personal chains get different lock keys" do
    @family.update!(personal_budgets: true)
    josh = users(:josh)
    @family.accounts.create!(
      accountable: CreditCard.new, name: "Josh Card", currency: "USD", balance: 0,
      status: "active", owner: josh
    )
    household = Budget.find_or_bootstrap(@family, start_date: Date.current)
    personal = Budget.find_or_bootstrap(@family, start_date: Date.current, user: josh, household: false)

    household_lock = capture_sql { recompute!(household) }.find { |s| s.include?("pg_advisory_xact_lock") }
    personal_lock = capture_sql { recompute!(personal) }.find { |s| s.include?("pg_advisory_xact_lock") }

    assert household_lock.present?, "the household chain must take a lock"
    assert personal_lock.present?, "the personal chain must take a lock"
    assert_not_equal household_lock, personal_lock, "each chain gets its own lock key"
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

    def credit_envelope_writes(&block)
      capture_sql(&block).select do |sql|
        sql.include?('"credit_envelopes"') && sql.match?(/\A\s*(INSERT|UPDATE)/)
      end
    end

    def create_card(name:)
      @family.accounts.create!(
        accountable: CreditCard.new, name: name, currency: "USD", balance: 0, status: "active"
      )
    end

    def create_checking
      @family.accounts.create!(
        accountable: Depository.new, name: "Checking", currency: "USD", balance: 10_000, status: "active"
      )
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

    def spend(budget, amount:, account:, category:)
      create_transaction(account: account, date: budget.start_date, amount: amount, category: category)
    end

    def pay(budget, amount:)
      Transfer::Creator.new(
        family: @family,
        source_account_id: @checking.id,
        destination_account_id: @card.id,
        date: budget.start_date,
        amount: amount
      ).create
    end

    def recompute!(budget)
      Budget::CreditEnvelopeCalculator.new(family: @family, budget: budget).recompute!
    end

    def envelope_for(budget, account)
      CreditEnvelope.find_by!(budget_id: budget.id, account_id: account.id)
    end
end
