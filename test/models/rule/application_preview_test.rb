require "test_helper"

class Rule::ApplicationPreviewTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Preview Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @merchant = @family.merchants.create!(name: "Whole Foods")
    @tag = @family.tags.create!(name: "Trips")
  end

  test "groups category changes by the category the transactions have now" do
    create_rule(
      name: "Groceries",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )
    uncategorized = create_transaction(account: @account, name: "Whole Foods Market", amount: 10).transaction
    dining = create_transaction(account: @account, name: "Whole Foods Bakery", amount: 20).transaction
    dining.update!(category: @dining)

    change = Rule::ApplicationPreview.new(@family).changes.sole

    assert_equal "set_transaction_category", change.action_type
    assert_equal 2, change.total

    groups = change.groups.index_by(&:from)
    assert_equal 1, groups[nil].count
    assert_equal @groceries.name, groups[nil].to
    assert_equal 1, groups[@dining.name].count
    assert_equal @groceries.name, groups[@dining.name].to
    assert_nil uncategorized.reload.category_id
  end

  test "summarises merchant, name and tag changes as well as categories" do
    create_rule(
      name: "Whole Foods",
      match: "Whole Foods",
      actions: [
        [ "set_transaction_category", @groceries.id.to_s ],
        [ "set_transaction_merchant", @merchant.id.to_s ],
        [ "set_transaction_name", "Groceries store" ],
        [ "set_transaction_tags", [ @tag.id ].join(",") ]
      ]
    )
    create_transaction(account: @account, name: "Whole Foods Market", amount: 10).transaction

    changes = Rule::ApplicationPreview.new(@family).changes.index_by(&:action_type)

    category = changes.fetch("set_transaction_category").groups.sole
    assert_nil category.from
    assert_equal @groceries.name, category.to
    assert_equal 1, category.count

    merchant = changes.fetch("set_transaction_merchant").groups.sole
    assert_nil merchant.from
    assert_equal @merchant.name, merchant.to

    name = changes.fetch("set_transaction_name").groups.sole
    assert_equal "Whole Foods Market", name.from
    assert_equal "Groceries store", name.to

    tags = changes.fetch("set_transaction_tags").groups.sole
    assert_nil tags.from
    assert_equal @tag.name, tags.to
  end

  test "a rule lower down does not take credit for a field a rule above already claims" do
    create_rule(
      name: "Top",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )
    create_rule(
      name: "Bottom",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @dining.id.to_s ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_equal [ "Top" ], changes.map { |change| change.rule.name }
    assert_equal @groceries.name, changes.sole.groups.sole.to
  end

  private
    def create_rule(name:, match:, actions:)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
        actions: actions.map { |action_type, value| Rule::Action.new(action_type: action_type, value: value) }
      )
    end
end
