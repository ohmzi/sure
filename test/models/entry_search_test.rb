require "test_helper"

# The "Written by the app" filter, as a query. This is the audit surface the
# owner reads to see exactly what the machine posted (spec N6): it must return
# the rows a machine wrote and nothing a person typed.
class EntrySearchAiPostedTest < ActiveSupport::TestCase
  setup do
    @machine = entries(:transaction_entry)
    @machine.update!(ai_posted_at: Time.current)
    @human = entries(:depository_transaction)
    @human.update!(ai_posted_at: nil)
  end

  # The brief's own test, against the real interface: the app instantiates a
  # search with a params hash and asks for a scoped relation
  # (`EntrySearch.new(params).build_query(scope)` — see `Entry.search` and
  # `Transaction::Search`), not the `new(entries:, params:).results` the brief
  # sketched.
  test "the ai_posted filter returns only machine-written entries" do
    results = EntrySearch.new({ ai_posted: "true" }).build_query(Entry.all)

    assert_includes results, @machine
    assert_not_includes results, @human
  end

  test "the filter absent, blank or explicitly off returns every row" do
    # The default must not narrow the ledger: only a truthy toggle applies it.
    assert_includes EntrySearch.new.build_query(Entry.all), @human
    assert_includes EntrySearch.new({ ai_posted: "" }).build_query(Entry.all), @human
    assert_includes EntrySearch.new({ ai_posted: "false" }).build_query(Entry.all), @human
  end

  test "a hand-entered row cannot be made to match the filter" do
    # The column is the only thing the filter reads, and no user-facing param
    # permits `ai_posted_at` (the transactions controller's `entry_params` and
    # `permitted_entry_params` do not list it), so the only writer is
    # `AutoPostReceiptJob`. A row a person typed stays nil and stays out.
    assert_nil @human.ai_posted_at, "a hand-typed row must not carry the marker"
    assert_not_includes EntrySearch.new({ ai_posted: "true" }).build_query(Entry.all), @human

    # Any casing ActiveModel::Type::Boolean casts truthy ("TRUE" included) just
    # applies the filter; the nil column is what keeps the hand-typed row out,
    # so no value a user could type can surface it.
    assert_not_includes EntrySearch.new({ ai_posted: "TRUE" }).build_query(Entry.all), @human
  end
end

class EntrySearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @account.entries.delete_all
  end

  test "search filters entries by category, tag, merchant and type like Transaction::Search" do
    food = create_transaction(account: @account, amount: 100, category: categories(:food_and_drink))
    other = create_transaction(account: @account, amount: 100, category: categories(:income))

    result_ids = @account.entries.search(
      { categories: [ "Food & Drink" ] }, @family
    ).pluck(:id)

    assert_includes result_ids, food.id
    assert_not_includes result_ids, other.id
  end

  test "category filter excludes non-Transaction entries (Valuations, Trades)" do
    uncategorized_txn = create_transaction(account: @account, amount: 100)
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ] }, @family
    ).pluck(:id)

    assert_includes result_ids, uncategorized_txn.id
    assert_not_includes result_ids, valuation.id
  end

  test "type filter excludes non-Transaction entries" do
    expense = create_transaction(account: @account, amount: 100, kind: "standard")
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search({ types: [ "expense" ] }).pluck(:id)

    assert_includes result_ids, expense.id
    assert_not_includes result_ids, valuation.id
  end

  test "type filter excludes non-Transaction entries even when every type is selected" do
    expense = create_transaction(account: @account, amount: 100, kind: "standard")
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search({ types: [ "expense", "income", "transfer" ] }).pluck(:id)

    assert_includes result_ids, expense.id
    assert_not_includes result_ids, valuation.id
  end

  test "merchant filter's No merchant bucket excludes non-Transaction entries" do
    without_merchant = create_transaction(account: @account, amount: 100)
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { merchants: [ Merchant::NO_MERCHANT_FILTER_VALUE ] }
    ).pluck(:id)

    assert_includes result_ids, without_merchant.id
    assert_not_includes result_ids, valuation.id
  end

  test "tag filter's Untagged bucket excludes non-Transaction entries" do
    without_tag = create_transaction(account: @account, amount: 100)
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { tags: [ Tag::UNTAGGED_FILTER_VALUE ] }
    ).pluck(:id)

    assert_includes result_ids, without_tag.id
    assert_not_includes result_ids, valuation.id
  end

  test "merchant filter for a real merchant name still excludes Valuations" do
    with_merchant = create_transaction(account: @account, amount: 100, merchant: merchants(:netflix))
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { merchants: [ merchants(:netflix).name ] }
    ).pluck(:id)

    assert_includes result_ids, with_merchant.id
    assert_not_includes result_ids, valuation.id
  end

  test "tag filter for a real tag name still excludes Valuations" do
    with_tag = create_transaction(account: @account, amount: 100, tags: [ tags(:one) ])
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { tags: [ tags(:one).name ] }
    ).pluck(:id)

    assert_includes result_ids, with_tag.id
    assert_not_includes result_ids, valuation.id
  end

  test "search / date / amount / status filters still apply to every entry type" do
    valuation = create_valuation(account: @account, amount: 5000)
    valuation.update!(name: "Reconciliation valuation")
    txn = create_transaction(account: @account, amount: 100, name: "Reconciliation check")

    result_ids = @account.entries.search({ search: "reconciliation" }).pluck(:id)

    assert_includes result_ids, valuation.id
    assert_includes result_ids, txn.id
  end

  test "without a transaction-specific filter, non-Transaction entries are not excluded" do
    valuation = create_valuation(account: @account)
    txn = create_transaction(account: @account, amount: 100)

    result_ids = @account.entries.search({}).pluck(:id)

    assert_includes result_ids, valuation.id
    assert_includes result_ids, txn.id
  end

  test "family is not required unless a category filter is used" do
    txn = create_transaction(account: @account, amount: 100, merchant: merchants(:netflix))

    result_ids = @account.entries.search({ merchants: [ merchants(:netflix).name ] }).pluck(:id)

    assert_includes result_ids, txn.id
  end
end
