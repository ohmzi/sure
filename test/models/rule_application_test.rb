require "test_helper"

class RuleApplicationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @user = users(:empty)
    @account = @family.accounts.create!(name: "Undo Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @entry = create_transaction(account: @account, name: "Whole Foods Market", amount: 10)
    @transaction = @entry.transaction
    @rule = @family.rules.create!(
      name: "Groceries",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id.to_s),
        Rule::Action.new(action_type: "set_transaction_name", value: "Groceries store")
      ]
    )
    @batch_id = SecureRandom.uuid
    ApplyAllRulesJob.perform_now(@family, actor: @user, batch_id: @batch_id)
    @application = RuleApplication.find_by!(batch_id: @batch_id, rule: @rule)
  end

  test "undo restores tags, merchant and the excluded flag too" do
    tag = @family.tags.create!(name: "Trips")
    merchant = @family.merchants.create!(name: "Corner Shop")
    entry = create_transaction(account: @account, name: "Corner Shop run", amount: 5)
    rule = @family.rules.create!(
      name: "Tag and exclude",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Corner Shop") ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_tags", value: tag.id.to_s),
        Rule::Action.new(action_type: "set_transaction_merchant", value: merchant.id.to_s),
        Rule::Action.new(action_type: "exclude_transaction")
      ]
    )
    batch_id = SecureRandom.uuid

    ApplyAllRulesJob.perform_now(@family, actor: @user, batch_id: batch_id)

    application = RuleApplication.find_by!(batch_id: batch_id, rule: rule)
    assert_equal [ tag.id ], entry.transaction.reload.tag_ids
    assert_equal merchant, entry.transaction.merchant
    assert entry.reload.excluded

    RuleApplication.undo_batch!(family: @family, batch_id: batch_id, actor: @user)

    assert_empty entry.transaction.reload.tag_ids
    assert_nil entry.transaction.merchant_id
    assert_not entry.reload.excluded
    assert_equal "undone", application.reload.status
  end

  test "records the rule, actor, prior values and affected transactions" do
    assert_equal @family, @application.family
    assert_equal @rule, @application.rule
    assert_equal @user, @application.user
    assert_equal @batch_id, @application.batch_id
    assert @application.applied_at.present?
    assert_equal [ @transaction.id ], @application.transaction_ids

    category = @application.attribute_changes.fetch(@transaction.id).fetch("category_id")
    assert_nil category["from"]
    assert_equal @groceries.id, category["to"]

    name = @application.attribute_changes.fetch(@transaction.id).fetch("name")
    assert_equal "Whole Foods Market", name["from"]
    assert_equal "Groceries store", name["to"]
  end

  test "undo restores the recorded prior values and records that it ran" do
    RuleApplication.undo_batch!(family: @family, batch_id: @batch_id, actor: @user)

    assert_nil @transaction.reload.category_id
    assert_equal "Whole Foods Market", @entry.reload.name

    @application.reload
    assert @application.undone_at.present?
    assert_equal "undone", @application.status
    assert_equal @user.id, @application.undone_by_id
    assert_empty @application.skipped_transaction_ids
  end

  test "undo is refused a second time" do
    RuleApplication.undo_batch!(family: @family, batch_id: @batch_id, actor: @user)

    assert_raises(RuleApplication::AlreadyUndone) do
      RuleApplication.undo_batch!(family: @family, batch_id: @batch_id, actor: @user)
    end
  end

  test "a transaction edited after the apply is skipped and flagged rather than overwritten" do
    @transaction.update!(category: @dining)

    RuleApplication.undo_batch!(family: @family, batch_id: @batch_id, actor: @user)

    assert_equal @dining, @transaction.reload.category
    assert_equal "Groceries store", @entry.reload.name, "the untouched attribute is left alone with the skipped row"

    @application.reload
    assert_equal [ @transaction.id ], @application.skipped_transaction_ids
    assert_equal "partially_undone", @application.status
    assert @application.undone_at.present?
  end

  test "undo locks the transaction and entry rows before restoring" do
    queries = capture_sql_queries do
      RuleApplication.undo_batch!(family: @family, batch_id: @batch_id, actor: @user)
    end

    assert queries.any? { |sql| sql.match?(/SELECT .* FROM "transactions".*FOR UPDATE/i) },
      "expected the transaction row to be locked"
    assert queries.any? { |sql| sql.match?(/SELECT .* FROM "entries".*FOR UPDATE/i) },
      "expected the entry row to be locked"
  end

  test "undoing one batch leaves another batch applied" do
    other_entry = create_transaction(account: @account, name: "Corner Shop", amount: 20)
    other_rule = @family.rules.create!(
      name: "Dining",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Corner Shop") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @dining.id.to_s) ]
    )
    other_batch = SecureRandom.uuid
    Rule::Runner.new(
      @family,
      rules: [ other_rule ],
      execution_type: "manual",
      application_batch_id: other_batch,
      actor: @user
    ).run

    RuleApplication.undo_batch!(family: @family, batch_id: @batch_id, actor: @user)

    assert_nil @transaction.reload.category_id
    assert_equal @dining, other_entry.transaction.reload.category
    other_application = RuleApplication.find_by!(batch_id: other_batch, rule: other_rule)
    assert_nil other_application.undone_at
  end

  test "undo unwinds overlapping additive tags in reverse order" do
    tag_a = @family.tags.create!(name: "Trips")
    tag_b = @family.tags.create!(name: "Business")
    entry = create_transaction(account: @account, name: "Tag Shop", amount: 5)
    @family.rules.create!(
      name: "Tag A",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Tag Shop") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_tags", value: tag_a.id.to_s) ]
    )
    @family.rules.create!(
      name: "Tag B",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Tag Shop") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_tags", value: tag_b.id.to_s) ]
    )
    batch_id = SecureRandom.uuid

    Rule::Runner.new(
      @family,
      rules: @family.rules,
      execution_type: "manual",
      application_batch_id: batch_id,
      actor: @user
    ).run

    assert_equal [ tag_a.id, tag_b.id ].sort, entry.transaction.reload.tag_ids.sort

    RuleApplication.undo_batch!(family: @family, batch_id: batch_id, actor: @user)

    assert_empty entry.transaction.reload.tag_ids
  end
end
