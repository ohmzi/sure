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

  test "a lower rule is matched by a rename a higher rule makes during the run" do
    create_rule(
      name: "Rename",
      match: "Whole Foods",
      actions: [ [ "set_transaction_name", "Supermarket" ] ]
    )
    create_rule(
      name: "Categorize the new name",
      match: "Supermarket",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )
    create_transaction(account: @account, name: "Whole Foods Market", amount: 10).transaction

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_equal [ "Rename", "Categorize the new name" ], changes.map { |change| change.rule.name }
    assert_equal @groceries.name, changes.last.groups.sole.to
  end

  test "a second rule adding an already-added tag is previewed as a no-op" do
    create_rule(
      name: "First tagger",
      match: "Whole Foods",
      actions: [ [ "set_transaction_tags", @tag.id.to_s ] ]
    )
    create_rule(
      name: "Second tagger",
      match: "Whole Foods",
      actions: [ [ "set_transaction_tags", @tag.id.to_s ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_equal [ "First tagger" ], changes.map { |change| change.rule.name }
    assert_equal @tag.name, changes.sole.groups.sole.to
  end

  test "stop processing keeps lower rules out of the preview" do
    @family.rules.create!(
      name: "Stop here",
      resource_type: "transaction",
      active: true,
      stop_processing: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id.to_s) ]
    )
    create_rule(
      name: "Never runs",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @dining.id.to_s ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_equal [ "Stop here" ], changes.map { |change| change.rule.name }
  end

  test "a transaction already holding the target value is not previewed as a change" do
    transaction = create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction
    transaction.update!(category: @groceries)
    create_rule(
      name: "Groceries",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )

    assert_empty Rule::ApplicationPreview.new(@family).changes
  end

  test "an AI action does not count transactions a higher rule already claimed" do
    create_rule(
      name: "Categories first",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )
    @family.rules.create!(
      name: "AI",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_nil changes.find { |change| change.action_type == "auto_categorize" }
  end

  test "a transfer action is previewed with a count that will not be undone" do
    target_account = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)
    create_rule(
      name: "Move to savings",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", target_account.id.to_s ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction

    change = Rule::ApplicationPreview.new(@family).changes.sole

    assert_equal "set_as_transfer_or_payment", change.action_type
    assert_equal 1, change.total
    assert_equal false, change.undoable
  end

  test "a notification action is previewed with a count that will not be undone" do
    create_rule(
      name: "Notify",
      match: "Whole Foods",
      actions: [ [ "send_email_notification", nil ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction

    change = Rule::ApplicationPreview.new(@family).changes.sole

    assert_equal "send_email_notification", change.action_type
    assert_equal 1, change.total
    assert_equal false, change.undoable
  end

  test "the preview does not issue per-transaction queries" do
    create_rule(
      name: "Groceries",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )
    3.times { |index| create_transaction(account: @account, name: "Whole Foods #{index}", amount: 10) }

    small = capture_sql_queries { Rule::ApplicationPreview.new(@family).changes }

    10.times { |index| create_transaction(account: @account, name: "Whole Foods extra #{index}", amount: 10) }
    large = capture_sql_queries { Rule::ApplicationPreview.new(@family).changes }

    assert_operator large.size, :<=, small.size + 1,
      "preview queries grew with transaction count: #{small.size} -> #{large.size}"
  end

  test "the preview loads only transactions the rules match" do
    create_rule(
      name: "Groceries",
      match: "Whole Foods",
      actions: [ [ "set_transaction_category", @groceries.id.to_s ] ]
    )
    30.times { |index| create_transaction(account: @account, name: "Unrelated merchant #{index}", amount: 5) }
    2.times { |index| create_transaction(account: @account, name: "Whole Foods #{index}", amount: 10) }

    preview = Rule::ApplicationPreview.new(@family)
    preview.changes

    assert_equal 2, preview.send(:states).size,
      "the preview should load the rule's matches, not every family transaction"
    assert_equal 2, preview.send(:transactions_by_id).size
  end

  test "a lower transaction_type rule no longer matches a transaction the transfer action converted" do
    target_account = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)
    create_rule(
      name: "Move to savings",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", target_account.id.to_s ] ]
    )
    type_rule = @family.rules.create!(
      name: "Still expenses",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_type", operator: "=", value: "expense") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @dining.id.to_s) ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10)

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_nil changes.find { |change| change.rule == type_rule },
      "the converted transaction and its counter-leg are not expenses"
  end

  test "a lower rule matches the counter-leg the transfer action creates" do
    income_category = @family.categories.create!(name: "Income")
    target_account = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)
    create_rule(
      name: "Move to savings",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", target_account.id.to_s ] ]
    )
    income_rule = @family.rules.create!(
      name: "Categorize the counter-leg",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_account", operator: "=", value: target_account.id) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: income_category.id.to_s) ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10)

    changes = Rule::ApplicationPreview.new(@family).changes
    change = changes.find { |candidate| candidate.rule == income_rule }

    assert change, "the counter-leg sits on the target account and is matched by lower rules"
    assert_equal 1, change.total
    assert_equal income_category.name, change.groups.sole.to
  end

  test "a lower transaction_type=transfer rule matches both transfer legs" do
    target_account = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)
    create_rule(
      name: "Move to savings",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", target_account.id.to_s ] ]
    )
    type_rule = @family.rules.create!(
      name: "See transfers",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_type", operator: "=", value: "transfer") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @dining.id.to_s) ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10)

    change = Rule::ApplicationPreview.new(@family).changes.find { |candidate| candidate.rule == type_rule }

    assert change
    assert_equal 2, change.total
  end

  test "a transfer that would create the investment contributions category is previewed as categorised" do
    brokerage = @family.accounts.create!(
      name: "Brokerage", balance: 0, currency: "USD", accountable: Investment.new(subtype: "brokerage")
    )
    create_rule(
      name: "Move to brokerage",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", brokerage.id.to_s ] ]
    )
    categorised_rule = category_condition_rule(
      name: "Categorised after the transfer",
      operator: "is_not_null",
      actions: [ [ "set_transaction_merchant", @merchant.id.to_s ] ]
    )
    uncategorised_rule = category_condition_rule(
      name: "Still uncategorised",
      operator: "is_null",
      actions: [ [ "set_transaction_name", "Should not run" ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10)

    changes = Rule::ApplicationPreview.new(@family).changes

    assert changes.any? { |change| change.rule == categorised_rule },
      "the real run assigns the category it creates, so the leg is no longer empty"
    assert_nil changes.find { |change| change.rule == uncategorised_rule }
    assert_equal 0, @family.categories.where(name: Category.all_investment_contributions_names).count,
      "the preview must not create the category"
  end

  test "a cc payment that would create the payment category is previewed as categorised" do
    card = @family.accounts.create!(
      name: "Credit Card", balance: 0, currency: "USD", accountable: CreditCard.new
    )
    create_rule(
      name: "Pay the card",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", card.id.to_s ] ]
    )
    categorised_rule = category_condition_rule(
      name: "Categorised after the payment",
      operator: "is_not_null",
      actions: [ [ "set_transaction_merchant", @merchant.id.to_s ] ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10)

    changes = Rule::ApplicationPreview.new(@family).changes

    assert changes.any? { |change| change.rule == categorised_rule },
      "confirm! creates and assigns the payment category, so the leg is no longer empty"
    assert_equal 0, @family.categories.where(name: payment_category_names).count,
      "the preview must not create the category"
  end

  test "a cc payment overwrites a category the automatic categorizer assigned" do
    card = @family.accounts.create!(
      name: "Credit Card", balance: 0, currency: "USD", accountable: CreditCard.new
    )
    payment_category = @family.credit_card_payment_category
    create_rule(
      name: "Pay the card",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", card.id.to_s ] ]
    )
    overwritten_rule = @family.rules.create!(
      name: "Now labelled as a payment",
      resource_type: "transaction",
      active: true,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods"),
        Rule::Condition.new(
          condition_type: "transaction_category", operator: "=", value: payment_category.id.to_s
        )
      ],
      actions: [ Rule::Action.new(action_type: "set_transaction_name", value: "Card payment") ]
    )

    guessed = create_transaction(account: @account, name: "Whole Foods", amount: 10).transaction
    guessed.update!(category: @dining)
    guessed.data_enrichments.create!(
      attribute_name: "category_id", source: "ai", value: @dining.id.to_s
    )
    manual = create_transaction(account: @account, name: "Whole Foods", amount: 20).transaction
    manual.update!(category: @groceries)

    change = Rule::ApplicationPreview.new(@family).changes.find { |candidate| candidate.rule == overwritten_rule }

    assert change, "the automatically assigned category is replaced by the payment category"
    assert_equal 1, change.total, "a category a person chose is left alone"
  end

  test "a transfer to the matched transaction's own account aborts the rest of its rule" do
    create_rule(
      name: "Same-account transfer",
      match: "Whole Foods",
      actions: [
        [ "set_as_transfer_or_payment", @account.id.to_s ],
        [ "set_transaction_category", @groceries.id.to_s ]
      ]
    )
    create_transaction(account: @account, name: "Whole Foods", amount: 10)

    changes = Rule::ApplicationPreview.new(@family).changes

    assert_empty changes, "the real run fails the transfer and skips the rule's later action"
  end

  test "the transfer preview does not issue per-candidate queries" do
    target_account = @family.accounts.create!(
      name: "Savings", balance: 0, currency: "USD", accountable: Depository.new
    )
    create_rule(
      name: "Move to savings",
      match: "Whole Foods",
      actions: [ [ "set_as_transfer_or_payment", target_account.id.to_s ] ]
    )
    3.times { |index| create_transaction(account: @account, name: "Whole Foods #{index}", amount: 10) }

    small = capture_sql_queries { Rule::ApplicationPreview.new(@family).changes }

    10.times { |index| create_transaction(account: @account, name: "Whole Foods extra #{index}", amount: 10) }
    large = capture_sql_queries { Rule::ApplicationPreview.new(@family).changes }

    assert_operator large.size, :<=, small.size + 1,
      "transfer preview queries grew with candidate count: #{small.size} -> #{large.size}"
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

    def category_condition_rule(name:, operator:, actions:)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: true,
        conditions: [
          Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods"),
          Rule::Condition.new(condition_type: "transaction_category", operator: operator)
        ],
        actions: actions.map { |action_type, value| Rule::Action.new(action_type: action_type, value: value) }
      )
    end

    def payment_category_names
      LanguagesHelper::SUPPORTED_LOCALES.filter_map do |locale|
        I18n.t(Category::CREDIT_CARD_PAYMENT_NAME_KEY, locale: locale, default: nil).presence
      end.uniq
    end
end
