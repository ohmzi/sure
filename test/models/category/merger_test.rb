require "test_helper"

class Category::MergerTest < ActiveSupport::TestCase
  setup do
    Current.reset
    @family = families(:dylan_family)
    @other_family = families(:empty)
  end

  teardown { Current.reset }

  test "merge! records one summary event with the affected count and actor" do
    Current.session = sessions(:one)
    Current.audit_source = "web"
    target = create_category(@family, "Audit Merge Target")
    source_a = create_category(@family, "Audit Merge Source A")
    source_b = create_category(@family, "Audit Merge Source B")
    create_transaction_for(@family, source_a)
    create_transaction_for(@family, source_b)

    assert_difference -> { AuditLog.count }, 1 do
      merger = Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source_a, source_b ]
      )

      assert merger.merge!
    end

    log = AuditLog.order(:created_at).last

    assert_equal "category.merged", log.action
    assert_equal @family, log.family
    assert_equal target, log.auditable
    assert_equal users(:family_admin), log.actor
    assert_equal "web", log.metadata["source"]
    assert_equal 2, log.metadata["affected_count"]
    assert_equal [ source_a.id, source_b.id ].sort, log.metadata["from_category_ids"].sort
    assert_equal [ source_a.name, source_b.name ].sort, log.metadata["from_category_names"].sort
    assert_equal target.id, log.metadata["to_category_id"]
    assert_equal target.name, log.metadata["to_category_name"]
  end

  test "a failed trail write rolls back the merge" do
    target = create_category(@family, "Audit Rollback Target")
    source = create_category(@family, "Audit Rollback Source")
    transaction = create_transaction_for(@family, source)

    AuditLog.stubs(:create!).raises(ActiveRecord::StatementInvalid.new("audit unavailable"))

    assert_raises(ActiveRecord::StatementInvalid) do
      Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source ]
      ).merge!
    end

    assert_equal source.id, transaction.reload.category_id
    assert Category.exists?(source.id)
  end

  test "merge only reassigns and deletes categories inside the current family" do
    target = create_category(@family, "Cross Family Merge Target")
    source = create_category(@family, "Cross Family Merge Source")
    source_child = create_category(@family, "Cross Family Merge Child", parent: source)
    transaction = create_transaction_for(@family, source)
    budget = create_budget(@family, 1.month.from_now.to_date.beginning_of_month)
    target_budget_category = create_budget_category(budget, target, 8)
    source_budget_category = create_budget_category(budget, source, 12)

    other_target = create_category(@other_family, target.name)
    other_source = create_category(@other_family, source.name)
    other_child = create_category(@other_family, source_child.name, parent: other_source)
    other_transaction = create_transaction_for(@other_family, other_source)
    other_budget = create_budget(@other_family, 1.month.from_now.to_date.beginning_of_month)
    other_source_budget_category = create_budget_category(other_budget, other_source, 30)

    other_family_snapshot = -> {
      {
        target_exists: Category.exists?(other_target.id),
        source_exists: Category.exists?(other_source.id),
        child_parent_id: other_child.reload.parent_id,
        transaction_category_id: other_transaction.reload.category_id,
        source_budgeted_spending: other_source_budget_category.reload.budgeted_spending
      }
    }

    assert_no_changes other_family_snapshot do
      merger = Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source ]
      )

      assert merger.merge!
    end

    assert_equal target.id, transaction.reload.category_id
    assert_equal target.id, source_child.reload.parent_id
    assert_equal 20.to_d, target_budget_category.reload.budgeted_spending
    assert_not BudgetCategory.exists?(source_budget_category.id)
    assert_not Category.exists?(source.id)
  end

  test "merging categories invalidates entries_cache_version" do
    target = create_category(@family, "Cache Merge Target")
    source = create_category(@family, "Cache Merge Source")
    transaction = create_transaction_for(@family, source)

    before = @family.reload.entries_cache_version

    travel 1.second do
      merger = Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source ]
      )

      assert merger.merge!
    end

    assert_equal target.id, transaction.reload.category_id
    assert_not_equal before, @family.reload.entries_cache_version
  end

  private
    def create_category(family, name, parent: nil)
      family.categories.create!(
        name: name,
        color: "#000000",
        lucide_icon: "shapes",
        parent: parent
      )
    end

    def create_transaction_for(family, category)
      transaction = Transaction.create!(category: category)
      Entry.create!(
        account: account_for(family),
        entryable: transaction,
        name: "#{category.name} transaction",
        date: Date.current,
        amount: 10,
        currency: family.currency || "USD"
      )

      transaction
    end

    def account_for(family)
      family.accounts.first || family.accounts.create!(
        accountable: Depository.create!(subtype: "checking"),
        name: "#{family.name} Checking",
        balance: 0,
        currency: family.currency || "USD"
      )
    end

    def create_budget(family, start_date)
      family.budgets.create!(
        start_date: start_date,
        end_date: start_date.end_of_month,
        currency: family.currency || "USD"
      )
    end

    def create_budget_category(budget, category, budgeted_spending)
      budget.budget_categories.create!(
        category: category,
        budgeted_spending: budgeted_spending,
        currency: budget.currency
      )
    end
end
