require "test_helper"

class IncomeStatement::AccountSankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @card = @family.accounts.create!(name: "Card", currency: "USD", balance: 0, accountable: CreditCard.new)
    @month = Date.new(2024, 2, 1)
    @salary = @family.categories.create!(name: "Salary", color: "#00aa00")
    @shopping = @family.categories.create!(name: "Shopping", color: "#123456")
    @groceries = @family.categories.create!(name: "Groceries", parent: @shopping)
  end

  test "flows run from income categories through each account to its own expense categories" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 300, @shopping)
    transaction(@card, 200, @groceries)
    result = graph

    assert_equal "net_by_account", result[:basis]
    assert_equal "1000.0", result[:income]
    assert_equal "500.0", result[:spending]
    assert_equal "500.0", result[:net_savings]
    assert_nil node(result, "cash_flow_node")
    assert_equal "account", node(result, "account_#{@checking.id}")[:kind]

    assert_link result, "income_#{@checking.id}_#{@salary.id}", "account_#{@checking.id}", "1000.0"
    assert_link result, "account_#{@checking.id}", "expense_#{@checking.id}_#{@shopping.id}", "300.0"
    assert_link result, "account_#{@card.id}", "expense_#{@card.id}_#{@shopping.id}", "200.0"
    assert_link result, "expense_#{@card.id}_#{@shopping.id}", "expense_sub_#{@card.id}_#{@groceries.id}", "200.0"
    assert_equal "200.0", node(result, "expense_#{@card.id}_#{@shopping.id}")[:value]
    assert_equal @groceries.filter_value, node(result, "expense_sub_#{@card.id}_#{@groceries.id}")[:filter_value]

    # Each account keeps its own category nodes, so the card's groceries and the
    # checking account's shopping are not merged.
    assert_not_equal "expense_#{@checking.id}_#{@shopping.id}", "expense_#{@card.id}_#{@shopping.id}"
    assert_balanced result
  end

  test "confirmed transfers flow between accounts and fund the card without a deficit" do
    transaction(@checking, -1000, @salary)
    transaction(@card, 200, @groceries)
    transfer_from_checking_to_card(200)
    result = graph

    assert_link result, "account_#{@checking.id}", "account_#{@card.id}", "200.0"
    assert_nil node(result, "deficit_node")
    assert_nil node(result, "balance_from_#{@card.id}")
    assert_link result, "account_#{@checking.id}", "balance_to_#{@checking.id}", "800.0"
    assert_balanced result
  end

  test "a card drawing more than its payments shows a savings-balance source, not a deficit" do
    transaction(@checking, -1000, @salary)
    transaction(@card, 300, @groceries)
    transfer_from_checking_to_card(200)
    result = graph

    assert_link result, "balance_from_#{@card.id}", "account_#{@card.id}", "100.0"
    assert_equal "From savings balance", node(result, "balance_from_#{@card.id}")[:name]
    assert_nil node(result, "deficit_node")
    assert_balanced result
  end

  test "a depository account drawing more than it takes in shows its own balance source" do
    transaction(@checking, -100, @salary)
    transaction(@checking, 300, @shopping)
    result = graph

    assert_link result, "balance_from_#{@checking.id}", "account_#{@checking.id}", "200.0"
    assert_equal "From Checking balance", node(result, "balance_from_#{@checking.id}")[:name]
    assert_balanced result
  end

  test "a card's credits are a sink, not income" do
    transaction(@checking, -1000, @salary)
    transaction(@card, -100, @salary)
    transaction(@card, 300, @groceries)
    transfer_from_checking_to_card(300)
    result = graph

    assert_equal "1000.0", result[:income]
    assert_link result, "account_#{@card.id}", "credits_#{@card.id}", "100.0"
    assert_equal "Card credits", node(result, "credits_#{@card.id}")[:name]
    assert_nil node(result, "income_#{@card.id}_#{@salary.id}")
    assert_balanced result
  end

  test "accounts without income, spending or transfers are left out, and an empty period is empty" do
    transaction(@checking, 50, @shopping)
    assert_nil node(graph, "account_#{@card.id}")
    assert_equal({ nodes: [], links: [] }, graph(Date.new(2023, 1, 1)).slice(:nodes, :links))
  end

  test "a category's per-account values add up to the category view" do
    transaction(@checking, 120, @shopping)
    transaction(@checking, -20, @shopping)
    transaction(@card, 50, @shopping)
    result = graph
    by_category = IncomeStatement::Sankey.new(IncomeStatement.new(@family), period: period).as_json

    assert_equal by_category[:spending], result[:spending]
    assert_equal by_category[:spending].to_d,
                 node(result, "expense_#{@checking.id}_#{@shopping.id}")[:value].to_d +
                 node(result, "expense_#{@card.id}_#{@shopping.id}")[:value].to_d
  end

  private
    def transaction(account, amount, category)
      create_transaction(account: account, amount: amount, category: category, date: @month)
    end

    def transfer_from_checking_to_card(amount)
      outflow = create_transaction(account: @checking, amount: amount, date: @month)
      inflow = create_transaction(account: @card, amount: -amount, date: @month)
      Transfer.create!(
        outflow_transaction: outflow.entryable,
        inflow_transaction: inflow.entryable,
        amount: amount
      ).confirm!
    end

    def period(month = @month)
      Period.custom(start_date: month, end_date: month.end_of_month)
    end

    def graph(month = @month)
      IncomeStatement::AccountSankey.new(IncomeStatement.new(@family), period: period(month)).as_json
    end

    def node(graph, id)
      graph[:nodes].find { |node| node[:id] == id }
    end

    def assert_link(graph, source_id, target_id, value)
      ids = graph[:nodes].map { |node| node[:id] }
      link = graph[:links].find { |l| l[:source] == ids.index(source_id) && l[:target] == ids.index(target_id) }
      assert link, "expected a link #{source_id} -> #{target_id}"
      assert_equal value, link[:value]
    end

    # Every account balances; every node's value is its larger side.
    def assert_balanced(graph)
      graph[:nodes].each do |node|
        index = graph[:nodes].index(node)
        incoming, outgoing = %i[target source].map do |end_point|
          graph[:links].select { |link| link[end_point] == index }.sum { |link| link[:value].to_d }
        end
        assert_operator node[:value].to_d, :>, 0
        assert_operator node[:percentage].to_d, :<=, 100
        assert_equal incoming, outgoing, "#{node[:id]} must balance" if node[:kind] == "account"
        assert_equal node[:value].to_d, [ incoming, outgoing ].max, "#{node[:id]} must match its links' capacity"
      end
    end
end
