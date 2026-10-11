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

  # (M8 Task 5; the moved M7 Task 10 SQL pin — the `.or(subquery)` over the
  # join, the part most likely to raise on relation incompatibility.)
  test "search matches a linked document's OCR snapshot and the filename fallback" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: @account,
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )
    link = DocumentLink.link_from_upload!(family: @family, uploader: users(:family_admin), source: "statement")
    link.update!(account_statement: statement, status: "unlinked")
    link.record_content!("ACME BANK STATEMENT\nTOTAL 1,234.00")

    assert_equal [ statement.id ], AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { search: "acme bank" }).relation.pluck(:id)
    assert_equal [ statement.id ], AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { search: statement.filename }).relation.pluck(:id)
    assert_empty AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { search: "no-such-text" }).relation.pluck(:id)
  end

  # -- the institution facet (M8 Task 7) ---------------------------------------

  test "the merchant filter matches the institution hint and blank filters nothing" do
    statement = AccountStatement.create_from_upload!(
      family: @family, account: @account,
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )
    statement.update!(institution_name_hint: "Acme Bank")

    found = AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { merchant: "acme" }).relation.pluck(:id)
    assert_includes found, statement.id

    assert_not_includes AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { merchant: "nobody" }).relation.pluck(:id), statement.id

    unfiltered = AccountStatement::Search.new(user: users(:family_admin), family: @family).relation.pluck(:id)
    assert_equal unfiltered, AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { merchant: "  " }).relation.pluck(:id)
  end

  test "a crafted amount param is ignored: statements have no amount facet" do
    unfiltered = AccountStatement::Search.new(user: users(:family_admin), family: @family).relation.count

    assert_equal unfiltered,
                 AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { amount_min: "10", amount_max: "15" }).relation.count
  end
end
