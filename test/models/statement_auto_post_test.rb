require "test_helper"

# The owner's rule (2026-10-16): a statement whose rows reconcile to its printed
# totals, carrying a card/account number that exactly one account already
# knows, posts itself. A duplicate month is flagged for the owner to delete —
# never posted, never deleted by Sure.
class StatementAutoPostTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @card = accounts(:credit_card)
    @card.update!(last4: "1512")
  end

  def statement_with_read(reconciled: true, last4: "1512", period: [ Date.new(2026, 5, 9), Date.new(2026, 6, 8) ], name: "june.pdf",
                          identity_source: "text_layer", rows_source: "text_layer")
    statement = AccountStatement.create_from_upload!(
      family: @family, account: nil,
      file: Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4 #{name} #{SecureRandom.hex(4)}"), "application/pdf", original_filename: name)
    )
    statement.update!(account_last4_hint: last4, period_start_on: period&.first, period_end_on: period&.last,
                      sanitized_parser_output: { "printed_last4s" => [ last4 ] })
    link = DocumentLink.create!(family: @family, source: "statement", status: "unlinked", account_statement: statement,
                                original_filename: name, created_by: users(:family_admin))
    extraction = DocumentExtraction.record!(document_link: link, status: "succeeded", ocr_text: "",
                                            verdict: { "document_class" => "statement" },
                                            validations: { "statement_totals_reconcile" => reconciled,
                                                           "identity_source" => identity_source,
                                                           "statement_rows_source" => rows_source })
    import = PdfImport.find_or_create_from_statement!(statement: statement)
    import.update!(document_extraction: extraction, document_type: "bank_statement", ai_summary: "Read", document_link: link,
                   extracted_data: { "transactions" => [
                     { "date" => "2026-05-12", "amount" => "-12.50", "name" => "Cafe", "notes" => "", "category" => "" }
                   ] })
    import.generate_rows_from_extracted_data
    import.sync_mappings
    import.update!(status: :pending)
    [ link, import ]
  end

  test "a proven statement with a number one account knows posts itself" do
    link, import = statement_with_read

    assert_enqueued_with(job: ImportJob) do
      assert_equal :posted, StatementAutoPost.call(link: link)
    end
    assert_equal "importing", import.reload.status
    assert_equal @card, link.account_statement.reload.account
  end

  test "a number no account knows waits for the owner's pick" do
    link, import = statement_with_read(last4: "9999")

    assert_equal :needs_account, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end

  test "a number two accounts know is never guessed" do
    accounts(:depository).update!(last4: "1512")
    link, import = statement_with_read

    assert_equal :needs_account, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end

  test "an unproven statement is never posted" do
    link, import = statement_with_read(reconciled: false)

    assert_equal :unverified, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end

  test "the same month for the same number is flagged as a duplicate, not posted, not deleted" do
    first, = statement_with_read(name: "june.pdf")
    StatementAutoPost.call(link: first)
    second, second_import = statement_with_read(name: "june-copy.pdf")

    assert_no_enqueued_jobs(only: ImportJob) do
      assert_equal :duplicate, StatementAutoPost.call(link: second)
    end

    hold = second.reload.hold_reason
    assert_equal "statement_duplicate", hold.code
    assert_includes hold.message, "june.pdf"
    assert_equal %w[delete], hold.actions
    assert_equal "pending", second_import.reload.status
    assert_not second_import.publishable?, "a flagged duplicate cannot be imported by hand either"
    assert_nil second.deleted_at, "Sure never deletes it; the owner does"
  end

  test "a month whose earlier copy the owner deleted is not a duplicate" do
    first, = statement_with_read(name: "june.pdf")
    first.update_columns(deleted_at: Time.current)
    second, = statement_with_read(name: "june-again.pdf")

    assert_not_equal :duplicate, StatementAutoPost.call(link: second)
  end

  # Review C2: a statement the owner reverted is a decision, not a statement
  # waiting for review — a re-read must never post it again.
  test "a statement the owner reverted never posts itself again" do
    link, import = statement_with_read
    StatementAutoPost.call(link: link)
    import.reload.publish
    assert import.reload.entries.any?, "posted"

    import.revert
    assert_empty import.reload.entries, "reverted"

    assert_no_enqueued_jobs(only: ImportJob) do
      assert_equal :reverted, StatementAutoPost.call(link: link.reload)
    end
  end


  # Review I2: only numbers the page prints decide the account — never one a
  # model supplied.
  test "an identity the model completed never auto-posts" do
    link, import = statement_with_read(identity_source: "text_layer+model")

    assert_equal :unverified, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end

  test "a hint with no printed number behind it decides nothing" do
    link, = statement_with_read
    link.account_statement.update!(sanitized_parser_output: {})

    assert_equal :needs_account, StatementAutoPost.call(link: link)
  end

  # Review I9 (owner's recommended option): rows a model read are reviewed by a
  # person even when they reconcile.
  test "rows a model read never auto-post, even when they reconcile" do
    link, import = statement_with_read(rows_source: "vision")

    assert_equal :unverified, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end

  # Review I3: with no period there is no duplicate check, so no auto-post.
  test "a statement with no period never auto-posts" do
    link, import = statement_with_read(period: nil)

    assert_equal :unverified, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end

  # Review I4: the uploader's own permission on the account still applies.
  test "an uploader who cannot write to the account never auto-posts into it" do
    link, import = statement_with_read
    Account.stubs(:writable_by).returns(Account.none)

    assert_equal :needs_account, StatementAutoPost.call(link: link)
    assert_equal "pending", import.reload.status
  end
end
