require "test_helper"

class Merchant::CanonicalizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, status: :active,
                                        accountable: Depository.new)
    @category = @family.categories.create!(name: "Shopping")
    transaction(100, "AMZN Mktp CA SAMPLE ON")
    transaction(50, "Amazon.ca SAMPLE ON")
    transaction(25, "THE HOME DEPOT #0000 SAMPLE ON")
  end

  test "merges similar names into canonical family merchants and rules" do
    Merchant::Canonicalizer.new(@family).call

    amazon = @family.merchants.find_by(name: "Amazon")
    home_depot = @family.merchants.find_by(name: "Home Depot")

    assert amazon.present?
    assert home_depot.present?
    assert_equal amazon.id, merchant_for("AMZN Mktp CA SAMPLE ON")
    assert_equal amazon.id, merchant_for("Amazon.ca SAMPLE ON")
    assert_equal home_depot.id, merchant_for("THE HOME DEPOT #0000 SAMPLE ON")

    rule = @family.rules.find_by(name: "Canonical merchant: Amazon")
    assert rule.present?
    assert_equal "transaction_name", rule.conditions.sole.condition_type
    assert_equal "set_transaction_merchant", rule.actions.sole.action_type
    assert_equal amazon.id.to_s, rule.actions.sole.value
  end

  test "is idempotent" do
    Merchant::Canonicalizer.new(@family).call

    assert_no_difference -> { @family.rules.count } do
      Merchant::Canonicalizer.new(@family).call
    end
    assert_equal 1, @family.rules.where(name: "Canonical merchant: Amazon").count
  end

  private
    def transaction(amount, name)
      create_transaction(account: @account, amount: amount, name: name, category: @category, date: Date.current)
    end

    def merchant_for(name)
      @family.transactions.joins(:entry).find_by(entries: { name: name }).merchant_id
    end
end
