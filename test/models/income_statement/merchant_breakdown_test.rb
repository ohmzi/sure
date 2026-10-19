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

  # The owner (2026-10-19): every merchant in a breakdown has its own colour,
  # even when two would hash to the same palette slot or share a set colour,
  # and the refunds are told apart from each other too.
  test "every merchant and every refund gets its own colour" do
    blue = @family.merchants.create!(name: "Blue One", type: "FamilyMerchant", color: "#6471eb")
    also_blue = @family.merchants.create!(name: "Blue Two", type: "FamilyMerchant", color: "#6471eb")
    transaction(amount: 90, merchant: blue, name: "Blue One")
    transaction(amount: 80, merchant: also_blue, name: "Blue Two")
    14.times { |i| transaction(amount: 10 + i, name: "Shop #{i}") }
    3.times { |i| transaction(amount: -(5 + i), name: "Refund #{i}") }

    result = breakdown
    colours = result.rows.map(&:color)
    refund_colours = result.refunds.map(&:color)

    assert_equal colours.size, colours.uniq.size, colours.inspect
    assert_equal refund_colours.size, refund_colours.uniq.size, refund_colours.inspect
    assert_empty colours & refund_colours
    assert_equal "#6471eb", result.rows.find { |row| row.name == "Blue One" }.color
    colours.each { |colour| assert_match(/\A#[0-9a-f]{6}\z/i, colour) }
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

  test "a refund reduces a merchant's net slice" do
    transaction(amount: 100, merchant: @amazon, name: "Amazon")
    transaction(amount: -40, merchant: @amazon, name: "Amazon refund")
    transaction(amount: 50, name: "Corner Store")

    result = breakdown

    assert_equal :spending, result.direction
    assert_equal [ "Amazon", "Corner Store" ], result.rows.map(&:name)
    assert_equal [ 60.0, 50.0 ], result.rows.map { |row| row.amount.to_f }
    assert_equal 110.0, result.total.to_f
    assert_empty result.refunds
  end

  test "a merchant whose refunds exceed purchases is listed as a refund" do
    transaction(amount: 100, merchant: @amazon, name: "Amazon")
    transaction(amount: -140, merchant: @amazon, name: "Amazon refund")
    transaction(amount: 50, name: "Corner Store")

    result = breakdown

    assert_equal :spending, result.direction
    assert_equal [ "Corner Store" ], result.rows.map(&:name)
    assert_equal [ "Amazon" ], result.refunds.map(&:name)
    assert_equal 40.0, result.refunds.first.amount.to_f
    assert result.refunds.first.negative
    assert_equal IncomeStatement::MerchantBreakdown::REFUND_COLOR, result.refunds.first.color
    assert_equal 10.0, result.net_total.to_f
  end

  test "merges similar merchant names into one canonical slice" do
    transaction(amount: 100, name: "AMZN Mktp CA SAMPLE ON")
    transaction(amount: 50, name: "Amazon.ca SAMPLE ON")
    transaction(amount: 25, name: "THE HOME DEPOT #0000 SAMPLE ON")

    result = breakdown

    assert_equal [ "Amazon", "Home Depot" ], result.rows.map(&:name)
    assert_equal [ 150.0, 25.0 ], result.rows.map { |row| row.amount.to_f }
    assert_equal [ 85.7, 14.3 ], result.rows.map(&:percentage)
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
