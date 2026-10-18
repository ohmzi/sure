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

  # -- the viewer's walk (P1.12): two LIMIT 1 keyset queries ------------------

  test "the walk returns first, middle and last neighbours over the filtered order" do
    base = Time.zone.parse("2026-09-01 12:00")
    walk_statement("walk_newest.csv", at: base + 3.hours)
    walk_statement("walk_middle.csv", at: base + 2.hours)
    walk_statement("walk_oldest.csv", at: base + 1.hour)
    # A statement between them in time but outside the filter is skipped.
    walk_statement("interloper.csv", at: base + 2.hours + 30.minutes)

    %w[newest oldest name document_date].each do |sort|
      search = AccountStatement::Search.new(user: users(:family_admin), family: @family,
                                            filters: { search: "walk_", sort: sort })
      ordered = search.relation.to_a
      assert_equal 3, ordered.size, "filtered list for #{sort}"
      assert_equal [ nil, ordered[1] ], search.neighbours(ordered[0]), "first for #{sort}"
      assert_equal [ ordered[0], ordered[2] ], search.neighbours(ordered[1]), "middle for #{sort}"
      assert_equal [ ordered[1], nil ], search.neighbours(ordered[2]), "last for #{sort}"
    end
  end

  test "a single matching statement has no neighbours, nor does one outside the filter" do
    only = walk_statement("alone.csv", at: Time.zone.parse("2026-09-01 12:00"))
    outside = walk_statement("outside.csv", at: Time.zone.parse("2026-09-01 12:00"))
    search = AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { search: "alone" })

    assert_equal [ nil, nil ], search.neighbours(only)
    assert_equal [ nil, nil ], search.neighbours(outside)
  end

  # A regression to the old full-id walk would load every matching id per open;
  # the walk must stay three bounded (LIMIT 1) keyset queries.
  test "the walk costs bounded keyset queries, never a full id load" do
    base = Time.zone.parse("2026-09-01 12:00")
    walk_statement("guard_newest.csv", at: base + 2.hours)
    middle = walk_statement("guard_middle.csv", at: base + 1.hour)
    search = AccountStatement::Search.new(user: users(:family_admin), family: @family, filters: { search: "guard_" })

    queries = capture_sql_queries { search.neighbours(middle) }
    statement_queries = queries.select { |sql| sql.include?('FROM "account_statements"') }

    walked = statement_queries.select { |sql| sql.include?("ORDER BY account_statements.") }
    assert_equal 2, walked.size, "one query per direction: #{statement_queries.inspect}"
    assert walked.all? { |sql| sql.match?(/\bLIMIT\s+\$?\d+\z/) },
           "each neighbour query is bounded: #{walked.inspect}"
    assert_empty statement_queries.grep(/\ASELECT "account_statements"\."id" FROM/),
                 "the walk must not pluck every matching id"
  end

  # The strip's buttons and the list they open must agree: both read the one
  # AccountStatement attention predicate, including its disjoint precedence.
  test "attention filters return exactly the shared attention scopes" do
    held = attention_statement("attention_held.csv")
    DocumentLink.create!(family: @family, source: "statement", status: "failed",
                         account_statement: held, original_filename: held.filename,
                         failure_message: "the reader could not open this document")

    attention_statement("attention_unmatched.csv", account: nil)
    attention_statement("attention_period.csv", period: false)
    attention_statement("attention_identity.csv", identity: false)
    attention_statement("attention_complete.csv")

    user = users(:family_admin)
    %w[held_or_failed unmatched missing_period missing_identity missing_printed_identity].each do |reason|
      canonical = reason == "missing_printed_identity" ? "missing_identity" : reason
      expected = AccountStatement.attention_scope(canonical, family: @family)
                                 .visible_to(user).pluck(:id).sort
      actual = AccountStatement::Search.new(user: user, family: @family,
                                            filters: { attention: reason }).relation.pluck(:id).sort

      assert_equal expected, actual, "the #{reason} list must be its shared scope"
    end
  end

  test "attention filters never list a rejected statement" do
    rejected = attention_statement("attention_rejected.csv")
    rejected.update_columns(review_status: "rejected", account_id: nil,
                            period_start_on: nil, period_end_on: nil,
                            account_last4_hint: nil, institution_name_hint: nil, account_name_hint: nil,
                            sanitized_parser_output: {})

    %w[held_or_failed unmatched missing_period missing_identity].each do |reason|
      assert_not_includes AccountStatement::Search.new(
        user: users(:family_admin), family: @family, filters: { attention: reason }
      ).relation, rejected
    end
  end

  test "an unknown attention value filters nothing" do
    expected = AccountStatement::Search.new(user: users(:family_admin), family: @family).relation.count

    assert_equal expected,
                 AccountStatement::Search.new(user: users(:family_admin), family: @family,
                                              filters: { attention: "bogus" }).relation.count
  end

  private
    def attention_statement(filename, account: @account, period: true, identity: true)
      statement = AccountStatement.create_from_upload!(
        family: @family, account: account,
        file: uploaded_file(filename: filename, content_type: "text/csv",
                            content: "date,amount\n2024-01-01,1\n#{filename}\n")
      )
      statement.update_columns(
        period_start_on: (Date.new(2026, 5, 1) if period),
        period_end_on: (Date.new(2026, 5, 31) if period),
        account_last4_hint: (identity ? "1234" : nil),
        institution_name_hint: nil, account_name_hint: nil,
        sanitized_parser_output: {}
      )
      statement
    end

    def walk_statement(filename, at:)
      @walk_count = (@walk_count || 0) + 1
      content = "date,amount\n#{at.to_date.iso8601},#{@walk_count}\n"
      statement = AccountStatement.create_from_upload!(
        family: @family, account: @account,
        file: Rack::Test::UploadedFile.new(StringIO.new(content), "text/csv", original_filename: filename)
      )
      statement.update_columns(created_at: at)
      statement
    end
end
