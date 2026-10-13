require "test_helper"

# The "Written by the app" filter, as a query. This is the audit surface the
# owner reads to see exactly what the machine posted (spec N6): it must return
# the rows a machine wrote and nothing a person typed.
class EntrySearchTest < ActiveSupport::TestCase
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
    results = EntrySearch.new(ai_posted: "true").build_query(Entry.all)

    assert_includes results, @machine
    assert_not_includes results, @human
  end

  test "the filter absent, blank or explicitly off returns every row" do
    # The default must not narrow the ledger: only a truthy toggle applies it.
    assert_includes EntrySearch.new.build_query(Entry.all), @human
    assert_includes EntrySearch.new(ai_posted: "").build_query(Entry.all), @human
    assert_includes EntrySearch.new(ai_posted: "false").build_query(Entry.all), @human
  end

  test "a hand-entered row cannot be made to match the filter" do
    # The column is the only thing the filter reads, and no user-facing param
    # permits `ai_posted_at` (the transactions controller's `entry_params` and
    # `permitted_entry_params` do not list it), so the only writer is
    # `AutoPostReceiptJob`. A row a person typed stays nil and stays out.
    assert_nil @human.ai_posted_at, "a hand-typed row must not carry the marker"
    assert_not_includes EntrySearch.new(ai_posted: "true").build_query(Entry.all), @human

    # Any casing ActiveModel::Type::Boolean casts truthy ("TRUE" included) just
    # applies the filter; the nil column is what keeps the hand-typed row out,
    # so no value a user could type can surface it.
    assert_not_includes EntrySearch.new(ai_posted: "TRUE").build_query(Entry.all), @human
  end
end
