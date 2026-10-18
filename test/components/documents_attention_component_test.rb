require "test_helper"

# The strip counts the asks; its buttons open lists. A count that disagrees
# with the list it links to is a broken promise, so every statement reason is
# measured against the same AccountStatement::Search relation the vault renders.
class DocumentsAttentionComponentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "each statement reason counts exactly the vault list it opens" do
    held = attention_statement("component_held.csv")
    DocumentLink.create!(family: @family, source: "statement", status: "failed",
                         account_statement: held, original_filename: held.filename,
                         failure_message: "the reader could not open this document")

    attention_statement("component_unmatched.csv", account: nil)
    attention_statement("component_period.csv", period: false)
    attention_statement("component_identity.csv", identity: false)

    component = DocumentsAttentionComponent.new(family: @family, user: @user)
    counts = {
      "held_or_failed" => component.held_or_failed,
      "unmatched" => component.unmatched_statements,
      "missing_period" => component.missing_period,
      "missing_identity" => component.missing_printed_identity
    }

    counts.each do |reason, count|
      list = AccountStatement::Search.new(user: @user, family: @family,
                                          filters: { attention: reason }).relation
      assert_equal list.count, count, "the #{reason} count must equal its list"
    end
  end

  test "rejected statements are never counted" do
    before = counts_for_family

    rejected = attention_statement("component_rejected.csv", period: false, identity: false)
    rejected.update_columns(review_status: "rejected", account_id: nil)

    assert_equal before, counts_for_family
  end

  test "a statement missing both is counted once, under missing period" do
    before = counts_for_family

    attention_statement("component_both.csv", period: false, identity: false)

    after = counts_for_family
    assert_equal before["missing_period"] + 1, after["missing_period"]
    assert_equal before["missing_identity"], after["missing_identity"],
                 "the identity ask must not repeat the period ask"
  end

  # A statement whose only document link was soft-deleted has left the archive:
  # both the vault list and the documents filter hide it. The strip must not
  # count an ask nobody can open, so every reason's count must equal its list.
  test "a tombstoned-only statement is counted under no reason" do
    before = counts_for_family
    tombstoned = {
      "held_or_failed" => tombstoned_statement("component_tombstone_held.csv", held: true),
      "unmatched" => tombstoned_statement("component_tombstone_unmatched.csv", account: nil),
      "missing_period" => tombstoned_statement("component_tombstone_period.csv", period: false),
      "missing_identity" => tombstoned_statement("component_tombstone_identity.csv", identity: false)
    }
    after = counts_for_family

    tombstoned.each do |reason, (statement, link)|
      list = AccountStatement::Search.new(user: @user, family: @family,
                                          filters: { attention: reason }).relation

      assert_equal before[reason], after[reason],
                   "the #{reason} count must not include a tombstoned statement"
      assert_equal list.count, after[reason], "the #{reason} count must equal its list"
      assert_not_includes list, statement
      assert_not_includes DocumentLink.needs_attention(@family), link
      assert_not_includes DocumentLink::Search.new(
        family: @family, filters: { attention: 1 }
      ).relation, link
    end
  end

  private
    def counts_for_family
      component = DocumentsAttentionComponent.new(family: @family, user: @user)
      {
        "held_or_failed" => component.held_or_failed,
        "unmatched" => component.unmatched_statements,
        "missing_period" => component.missing_period,
        "missing_identity" => component.missing_printed_identity
      }
    end

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

    # A statement whose ONLY document link was soft-deleted: the tombstone case
    # the lists drop and the strip used to keep counting.
    def tombstoned_statement(filename, account: @account, period: true, identity: true, held: false)
      statement = attention_statement(filename, account: account, period: period, identity: identity)
      link = DocumentLink.create!(
        family: @family, source: "statement", status: (held ? "failed" : "unlinked"),
        account_statement: statement, original_filename: statement.filename,
        content_type: statement.content_type,
        failure_message: (held ? "the reader could not open this document" : nil)
      )
      assert link.soft_delete!, "the fixture link must be soft-deletable"
      [ statement, link ]
    end
end
