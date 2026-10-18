require "test_helper"

class Category::MerchantCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, status: :active,
                                        accountable: Depository.new)
    @shopping = @family.categories.create!(name: "Shopping")
    @food = @family.categories.create!(name: "Food & Drink")
    @home = @family.categories.create!(name: "Home Improvement")
    @subscriptions = @family.categories.create!(name: "Subscriptions")

    transaction(100, "AMZN Mktp CA SAMPLE ON")
    transaction(30, "TIM HORTONS #0000 SAMPLE ON")
    transaction(40, "THE HOME DEPOT #0000 SAMPLE ON")
    transaction(15, "Amazon Channels SAMPLE ON", category: @subscriptions)
  end

  test "fills uncategorized merchants from the known patterns" do
    Category::MerchantCategorizer.new(@family).call

    assert_equal @shopping.id, category_for("AMZN Mktp CA SAMPLE ON")
    assert_equal @food.id, category_for("TIM HORTONS #0000 SAMPLE ON")
    assert_equal @home.id, category_for("THE HOME DEPOT #0000 SAMPLE ON")
  end

  test "never overwrites a category that already exists" do
    Category::MerchantCategorizer.new(@family).call

    assert_equal @subscriptions.id, category_for("Amazon Channels SAMPLE ON")
  end

  test "creates one rule per category and is idempotent" do
    Category::MerchantCategorizer.new(@family).call

    assert_equal 1, @family.rules.where(name: "Categorize Shopping merchants").count
    assert_no_difference -> { @family.rules.count } do
      Category::MerchantCategorizer.new(@family).call
    end
  end

  private
    def transaction(amount, name, category: nil)
      create_transaction(account: @account, amount: amount, name: name, category: category, date: Date.current)
    end

    def category_for(name)
      @family.transactions.joins(:entry).find_by(entries: { name: name }).category_id
    end
end
