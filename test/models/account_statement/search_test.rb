require "test_helper"

class AccountStatement::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "keeps the per-user visibility scope and filters review and extraction" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: @account,
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )

    search = AccountStatement::Search.new(user: users(:family_admin), family: @family)
    assert_includes search.relation.pluck(:id), statement.id

    # (repaired 2026-10-11, dispatchability check) the statement is created with an
    # account, so the app forces review_status `linked` (sync_review_status): the
    # filter MUST include it under `linked` and EXCLUDE it under `unmatched` - the
    # pre-repair assertions were inverted and could never pass.
    linked_only = AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { review: %w[linked] })
    assert_includes linked_only.relation.pluck(:id), statement.id

    unmatched = AccountStatement::Search.new(user: users(:family_member), family: @family, filters: { review: %w[unmatched] })
    assert_not_includes unmatched.relation.pluck(:id), statement.id
  end

  test "an unknown review value filters nothing instead of widening" do
    assert_equal AccountStatement::Search.new(user: users(:family_admin), family: @family).relation.count,
                 AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { review: %w[bogus] }).relation.count
  end
end
