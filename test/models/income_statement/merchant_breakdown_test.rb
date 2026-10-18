require "test_helper"

class IncomeStatement::MerchantBreakdownTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, status: :active,
                                        accountable: Depository.new)
    @category = @family.categories.create!(name: "Shopping")
    @amazon = @family.merchants.create!(name: "Amazon", type: "FamilyMerchant")
    @period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)
  end

  test "builds spending slices by merchant, sorted by amount" do
    transaction(amount: 100, merchant: @amazon, name: "Amazon")
    transaction(amount: 50, merchant: @amazon, name: "Amazon 2")
    transaction(amount: 25, name: "Corner Store")

    result = breakdown

    assert_equal :spending, result.direction
    assert_equal 175.0, result.total.to_f
    assert_equal [ "Amazon", "Corner Store" ], result.rows.map(&:name)
    assert_equal [ 85.7, 14.3 ], result.rows.map(&:percentage)
    assert result.rows.first.id.start_with?("merchant-")
    assert_equal @amazon.id.to_s, result.rows.first.merchant_id
    assert_equal @amazon.color, result.rows.first.color
    assert_nil result.rows.last.merchant_id
    assert_match(/\A#[0-9a-f]{6}\z/i, result.rows.last.color)
  end

  test "an income category keeps only the income side and shows absolute slices" do
    salary = @family.categories.create!(name: "Salary")
    transaction(amount: -500, category: salary, merchant: @amazon, name: "Pay")
    transaction(amount: 100, category: salary, merchant: @amazon, name: "Reversal")

    result = breakdown(category: salary)

    assert_equal :income, result.direction
    assert_equal 400.0, result.total.to_f
    assert_equal 100.0, result.rows.first.percentage
  end

  test "a category with no merchant activity is empty" do
    result = breakdown

    assert_empty result.rows
    assert_equal 0, result.total
  end

  private
    def breakdown(category: @category)
      IncomeStatement::MerchantBreakdown.new(IncomeStatement.new(@family), category: category, period: @period).call
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
