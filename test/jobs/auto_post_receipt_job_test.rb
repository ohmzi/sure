require "test_helper"

# The integration half of the auto-post (spec N6): the gate's four conditions
# are pinned as a pure function in test/models/auto_post_test.rb; this file pins
# what the writer does with real rows — the identity it mints, the replay guard,
# the provenance edge, and what a refusal leaves behind.
class AutoPostReceiptJobTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    # A draft that clears every gate condition: account depository, total 12.00,
    # purchase date 2026-09-14, its link classified `ai`, and its link's latest
    # read agreeing that the totals match.
    #
    # (fix round 1, ruling 4) The receipt carries NO item lines and its rows are
    # generated here, exactly as the pipeline's `apply_extraction!` would. The
    # fixture `receipt_understood` stores line items that sum exactly to the
    # total but never generated their rows, so its `line_items_split?` was false
    # only because no rows existed — in production that same receipt would split
    # and the gate would refuse it. This draft is the shape the real pipeline
    # would genuinely auto-post.
    @draft = imports(:receipt_understood)
    @account = accounts(:depository)
    @draft.update!(extracted_data: @draft.extracted_data.merge("line_items" => []))
    @draft.generate_rows_from_line_items!
    assert_equal 0, @draft.reload.rows_count, "a single-transaction receipt has no item rows"
    assert_not @draft.line_items_split?, "and so is never a split"
  end

  def posted_entry
    Entry.find_by(account: @account, external_id: "document:#{@draft.document_link_id}")
  end

  test "a gated receipt posts itself through the adapter with the document identity" do
    assert_difference -> { Entry.count }, 1 do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    entry = posted_entry
    assert_not_nil entry
    assert_equal "document", entry.source
    assert_equal BigDecimal("12.00"), entry.amount
    assert_equal Date.new(2026, 9, 14), entry.date
    assert_equal "Starbucks", entry.name
    assert_not_nil entry.ai_posted_at, "the entry must say a machine wrote it"
    assert_equal @draft.id, entry.import_id
    assert entry.import_locked?, "a sync must never overwrite a machine-written entry"
    assert_equal "Transaction", entry.entryable_type

    link = @draft.document_link.reload
    assert_equal "linked", link.status
    assert_equal entry.id, link.entry_id, "the provenance edge points at the entry"
  end

  test "a re-delivered job never posts twice" do
    AutoPostReceiptJob.perform_now(@draft.id)
    assert_not_nil posted_entry

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_equal 1, Entry.where(account: @account, external_id: "document:#{@draft.document_link_id}").count
  end

  test "the identity is the same one the reviewed publish mints" do
    # The replay-safe identity is not cosmetic: it is what makes an auto-post and
    # a manual publish of the SAME document one entry rather than two.
    AutoPostReceiptJob.perform_now(@draft.id)
    entry = posted_entry

    assert_equal "document:#{@draft.document_link_id}", entry.external_id
    assert_equal "document", entry.source
    assert_equal @account, entry.account
  end

  # (fix round 1, ruling 5) The two writers converge on ONE entry. The realistic
  # case: the receipt auto-posts, the user then taps publish on the draft that is
  # still sitting in the review strip. The reviewed publish must not mint a
  # second entry.
  test "a manual publish after an auto-post converges on the one entry" do
    AutoPostReceiptJob.perform_now(@draft.id)
    auto = posted_entry
    assert_not_nil auto

    assert_no_difference -> { Entry.count } do
      @draft.reload.publish
    end

    assert_equal 1, Entry.where(account: @account, external_id: "document:#{@draft.document_link_id}").count
    assert_equal auto.id, posted_entry.id, "both paths resolve to the same entry"
    assert_equal @draft.id, auto.reload.import_id
    assert @draft.reload.complete?, "the manual publish settles the draft that auto-posted"
  end

  # (fix round 1, ruling 5) Even where the committed-data guard is not what stops
  # the second write, the document IDENTITY is: the adapter's
  # `find_or_initialize_by(external_id:, source:)` is the mechanism that keeps the
  # two writers from producing two rows. Drive it directly.
  test "the document identity itself dedups across writers" do
    AutoPostReceiptJob.perform_now(@draft.id)
    auto = posted_entry

    again = Account::ProviderImportAdapter.new(@account).import_transaction(
      external_id: "document:#{@draft.document_link_id}", source: "document",
      amount: @draft.total_amount, currency: @account.currency, date: @draft.purchase_date,
      name: "Some Other Name", allow_heuristic_matching: false
    )

    assert_equal auto.id, again.id, "the same identity must resolve to the same entry"
    assert_equal 1, Entry.where(account: @account, external_id: "document:#{@draft.document_link_id}").count
  end

  test "the household switch turns the writer off" do
    Setting.auto_post_receipts = false

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end
    assert_equal "unlinked", @draft.document_link.reload.status
  ensure
    Setting.auto_post_receipts = true
  end

  test "a refusal leaves the document exactly as it was: reviewable, not posted, not wedged" do
    # `receipt_draft` is awaiting_ocr with no account and a link that has no read
    # — every condition fails. The refusal must be a pure no-op on the document.
    draft = imports(:receipt_draft)
    link = draft.document_link.reload
    before = link.attributes.slice("status", "entry_id", "failure_message")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(draft.id)
    end

    link.reload
    assert_equal before, link.attributes.slice("status", "entry_id", "failure_message")
    assert_equal "unlinked", link.status
    assert_nil link.entry_id
  end

  # (fix round 1, ruling RB8) A bill is an invoice that may be unpaid; auto-posting
  # it would write an expense that never happened. It is read and drafted, then
  # waits for the one tap — even when every gate condition is satisfied.
  test "a bill that clears every gate condition still never auto-posts" do
    @draft.document_link.update!(source: "bill")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    link = @draft.document_link.reload
    assert_equal "unlinked", link.status
    assert_nil link.entry_id
    assert_equal "understood", @draft.reload.understanding_state, "the bill stays reviewable"
  end

  test "a split receipt is never auto-posted" do
    # Two item lines that sum exactly to the total become a split — several
    # entries, not one thing to write. This is the `single_transaction?` pin
    # against real rows, built the way the pipeline builds rows.
    @draft.update!(extracted_data: @draft.extracted_data.merge("line_items" => [
      { "description" => "Latte", "amount" => "4.75" },
      { "description" => "Sandwich", "amount" => "7.25" }
    ]))
    @draft.generate_rows_from_line_items!
    assert @draft.reload.line_items_split?, "the lines must actually sum to the total, or the gate is untested"

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end
    assert_equal "unlinked", @draft.document_link.reload.status
  end

  test "a nil totals_agree refuses even with every other condition green" do
    # A nil means the cheap read could not check the total (no labelled total in
    # the OCR text) — not agreement. The rest of this draft is untouched and
    # would otherwise pass.
    @draft.document_link.extraction.update!(validations: { "totals_agree" => nil })

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end
  end

  # The carried-in Task 9 gap, at the writer: the undo removed the entry and
  # cleared the draft's `data_committed?`, so a reprocess re-enqueues this job.
  # The DURABLE reversal on the document is what stops the machine silently
  # re-posting money the user took back.
  test "a document whose auto-post the user undid is never re-posted" do
    @draft.document_link.update!(auto_post_undone_at: Time.current)
    before = @draft.document_link.reload.attributes.slice("status", "entry_id")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    link = @draft.document_link.reload
    assert_equal before, link.attributes.slice("status", "entry_id"),
                 "the refusal is a pure no-op on the document"
  end

  test "an entry a human already recorded is never claimed" do
    # `allow_heuristic_matching: false` — auto-post writes a new entry, never
    # adopts the user's. The receipt's own identity is `document:<link id>`, so
    # even with a same-amount manual row present, the writer mints its own.
    create_transaction(account: @account, date: Date.new(2026, 9, 14), amount: 12, name: "Starbucks")
    manual = @account.entries.find_by(external_id: nil, amount: 12)

    assert_difference -> { Entry.count }, 1 do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_nil manual.reload.external_id, "the manual entry must be left exactly as it was"
    assert_not_equal manual.id, posted_entry.id
  end

  # --- the provenance edge (fix round 1, finding 1) ---------------------------
  #
  # The write must not silently commit money with no edge. Two cases: a link the
  # user DISMISSED still records the edge (the publish path widened to
  # PUBLISH_LINKABLE for exactly this), and a link in a status that cannot be
  # linked RAISES so the money rolls back.

  test "a dismissed link still records the provenance edge" do
    link = @draft.document_link
    assert link.dismiss!
    assert_equal "dismissed", link.reload.status

    assert_difference -> { Entry.count }, 1 do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    entry = posted_entry
    assert_not_nil entry
    link.reload
    assert_equal "linked", link.status, "the write records the edge rather than dropping it"
    assert_equal entry.id, link.entry_id
  end

  test "a link that cannot be linked raises and writes no money" do
    # `failed` is outside both LINKABLE and PUBLISH_LINKABLE, so the edge cannot
    # be recorded. The raise inside the lock rolls the whole write back: no entry,
    # and the link is left as it was — never money with no provenance.
    link = @draft.document_link
    link.update_columns(status: "failed")

    assert_raises(RuntimeError) do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_nil posted_entry, "the raise must roll the entry back, not commit it"
    link.reload
    assert_equal "failed", link.status
    assert_nil link.entry_id
  end

  # --- Task 7's evidence match: the milestone's most consequential interaction -
  #
  # A receipt auto-posted today must still be claimable by the statement that
  # arrives next week. That works because the auto-posted entry carries the
  # document identity and lands on the real account: the statement's match is an
  # evidence match (account, amount, currency, ±3 days), not an id comparison.
  test "a statement that arrives later claims the entry the auto-post wrote" do
    AutoPostReceiptJob.perform_now(@draft.id)
    posted = posted_entry
    assert_not_nil posted, "the receipt must post before the statement arrives"

    statement = create_pdf_statement(account: @account)
    statement_link = statement.archive_document_link!
    # archive_document_link! caches a nil read of its own has_one while building
    # the link; re-read before the import shares the same statement object.
    statement.reload

    import = PdfImport.create_from_statement!(statement: statement)
    import.update!(account: @account, extracted_data: { "transactions" => [
      # An expense two days off, under the extractor's signed convention
      # (PdfImport's signage makes the stored entry amount +12.00).
      { "date" => "2026-09-16", "amount" => "-12.00", "name" => "STARBUCKS", "notes" => "" }
    ] })
    import.generate_rows_from_extracted_data
    assert_equal 0, import.reload.rows_count, "the statement line matches the machine-written entry"

    assert_no_difference -> { Entry.count } do
      import.import!
    end

    posted.reload
    assert_equal statement.id, posted.reconciled_by_statement_id,
                 "the statement must claim the entry the auto-post wrote"
    assert_includes posted.document_links.map(&:id), statement_link.id,
                    "both documents must be visible on the one transaction"
  end

  private
    def create_pdf_statement(account:)
      AccountStatement.create_from_upload!(
        family: account.family,
        account: account,
        file: uploaded_file(
          filename: "sample_bank_statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
