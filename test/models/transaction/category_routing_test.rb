require "test_helper"

# The owner (2026-10-19): a category can say where its money goes — label a
# card charge "Investment Contributions" and it lands in the investment
# account the category names, as a transfer, not as spending.
class Transaction::CategoryRoutingTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @investment = accounts(:investment)
    @category = families(:dylan_family).categories.create!(name: "Gold", color: Category::COLORS.first, destination_account: @investment)
  end

  test "an outflow given a routed category becomes a transfer into its account" do
    entry = create_transaction(account: accounts(:depository), amount: 250, name: "Gold bar")

    entry.transaction.update!(category: @category)

    transfer = entry.transaction.reload.transfer
    assert transfer&.confirmed?, "the charge should be the outflow of a confirmed transfer"
    assert_equal entry.transaction, transfer.outflow_transaction
    inflow = transfer.inflow_transaction.entry
    assert_equal @investment, inflow.account
    assert_equal(-250, inflow.amount)
    assert_equal "Gold bar", inflow.name
    assert_equal "investment_contribution", entry.transaction.reload.kind
    assert_equal @category, entry.transaction.category
  end

  test "an outflow created with a routed category is routed too" do
    entry = create_transaction(account: accounts(:depository), amount: 80, category: @category)

    assert entry.transaction.reload.transfer.present?
  end

  test "inflows, transfers and charges already in the account are left alone" do
    inflow = create_transaction(account: accounts(:depository), amount: -40)
    own = create_transaction(account: @investment, amount: 30)

    assert_no_difference "Transfer.count" do
      inflow.transaction.update!(category: @category)
      own.transaction.update!(category: @category)
    end
  end

  test "routing twice does not make a second transfer" do
    entry = create_transaction(account: accounts(:depository), amount: 60)
    entry.transaction.update!(category: @category)

    assert_no_difference "Transfer.count" do
      Transaction::CategoryRouting.new(entry.transaction.reload).route!
    end
  end

  test "a category moves the transactions already in it" do
    @category.update!(destination_account: nil)
    first = create_transaction(account: accounts(:depository), amount: 20, category: @category)
    second = create_transaction(account: accounts(:depository), amount: 35, category: @category)
    @category.update!(destination_account: @investment)

    assert_equal 2, @category.reload.route_existing_transactions!
    assert first.transaction.reload.transfer.present?
    assert second.transaction.reload.transfer.present?
    assert_equal 0, @category.route_existing_transactions!
  end

  test "only an investment account of the family can be chosen" do
    @category.destination_account = accounts(:depository)
    assert_not @category.valid?
  end

  test "a category without an account changes nothing" do
    entry = create_transaction(account: accounts(:depository), amount: 60)

    assert_no_difference "Transfer.count" do
      entry.transaction.update!(category: categories(:income))
    end
  end
end
