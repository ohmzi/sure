require "test_helper"

class IncomeStatement::MerchantTotalsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, status: :active,
                                        accountable: Depository.new)
    @category = @family.categories.create!(name: "Shopping")
    @subcategory = @family.categories.create!(name: "Clothing", parent: @category)
    @other_category = @family.categories.create!(name: "Groceries")
    @amazon = @family.merchants.create!(name: "Amazon", type: "FamilyMerchant")
    @netflix = @family.merchants.create!(name: "Netflix", type: "FamilyMerchant")
    @period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)
  end

  test "groups spending by merchant, falling back to the transaction name" do
    transaction(amount: 100, merchant: @amazon, name: "Amazon order")
    transaction(amount: 50, merchant: @amazon, name: "Amazon order 2")
    transaction(amount: 25, name: "Corner Store")
    transaction(amount: 30, merchant: @netflix, name: "Netflix", category: @subcategory)
    transaction(amount: 999, category: @other_category, name: "Ignored")

    rows = totals

    assert_equal [ [ "Amazon", 150.0 ], [ "Netflix", 30.0 ], [ "Corner Store", 25.0 ] ],
                 rows.map { |row| [ row.name, row.total.to_f ] }
  end

  test "keeps spending, refunds and the net separately" do
    transaction(amount: 100, merchant: @amazon, name: "Amazon order")
    transaction(amount: -40, merchant: @amazon, name: "Amazon refund")

    row = totals.first

    assert_equal 100.0, row.spending.to_f
    assert_equal 40.0, row.income.to_f
    assert_equal 60.0, row.total.to_f
  end

  private
    def totals
      IncomeStatement.new(@family).merchant_totals(category: @category, period: @period)
    end

    def transaction(amount:, name:, category: @category, merchant: nil)
      create_transaction(
        account: @account,
        amount: amount,
        name: name,
        category: category,
        merchant: merchant,
        date: Date.current
      )
    end
end
