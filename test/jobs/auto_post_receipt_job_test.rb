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

  # --- W3-1: never double-post a charge the account already holds ------------
  #
  # The milestone's hardest interaction (spec §8.6, statement-first ordering): if
  # the account already recorded the charge — from a statement or a bank sync —
  # the receipt must CORROBORATE it, not mint a second entry. Exactly one entry
  # for one charge, always.

  test "a receipt never double-posts a charge a statement already recorded" do
    # The statement landed first and recorded the charge under its own identity
    # (statement rows carry no external_id). The receipt's auto-post must attach
    # to it as the §8.6 "corroborated by" edge, not create a duplicate.
    statement_entry = create_transaction(
      account: @account, date: Date.new(2026, 9, 16), amount: 12, name: "STARBUCKS"
    )

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_equal 1, Entry.where(account: @account, amount: 12, currency: "USD").count
    link = @draft.document_link.reload
    assert_equal "linked", link.status
    assert_equal statement_entry.id, link.entry_id,
                 "the receipt corroborates the charge the statement already recorded"
  end

  test "a receipt never double-posts a charge the bank sync already recorded" do
    # The existing charge arrived by sync, so it carries an external_id. The
    # match must reach it too (include_provider_entries), or a synced charge
    # would be duplicated. Its identity is left exactly as it was.
    synced = @account.entries.create!(
      name: "STARBUCKS #1234", date: Date.new(2026, 9, 15), amount: 12,
      currency: "USD", source: "simplefin", external_id: "simplefin_abc",
      entryable: Transaction.new
    )

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_equal synced.id, @draft.document_link.reload.entry_id
    assert_equal "simplefin_abc", synced.reload.external_id,
                 "the synced entry's identity must be left exactly as it was"
  end

  test "an auto-post corroborates a same-charge row a person recorded, and writes no money" do
    # A person typed the same charge by hand. Under statement-first ordering the
    # receipt corroborates that row (spec §8.6) rather than minting a second
    # entry for the one charge.
    manual = create_transaction(account: @account, date: Date.new(2026, 9, 14), amount: 12, name: "Starbucks")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_nil manual.reload.external_id, "the manual entry's identity is left exactly as it was"
    assert_equal manual.id, @draft.document_link.reload.entry_id,
                 "the receipt is attached to the charge it corroborates"
  end

  test "a duplicate the receipt cannot safely corroborate falls to review, writing no money" do
    # The charge is already held, so the writer must corroborate it. But the link
    # is in a status that cannot record the edge (`failed` is outside both
    # LINKABLE and PUBLISH_LINKABLE), so attaching is not safe: the auto-post
    # falls to review rather than minting a second entry for the same charge.
    create_transaction(account: @account, date: Date.new(2026, 9, 14), amount: 12, name: "Starbucks")
    link = @draft.document_link
    link.update_columns(status: "failed")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    link.reload
    assert_nil link.entry_id, "the edge could not be recorded, so nothing was written"
    assert_equal "failed", link.status
  end

  # --- W3-1 identity signal: a wrong "corroborated by" edge is the provenance
  # lie this milestone exists to prevent -------------------------------------
  #
  # An existing entry only counts as the SAME charge when the receipt's payee and
  # the entry's name carry the same identity. Amount/date alone is not enough.

  test "an unrelated same-amount entry is not corroborated: the receipt falls to review" do
    # Same amount, currency and window — but a different merchant. Linking it
    # would make the receipt read as "corroborated by" a charge it isn't (and
    # block the receipt's own deletion); minting would double the account. So the
    # auto-post falls to review and writes nothing.
    unrelated = create_transaction(account: @account, date: Date.new(2026, 9, 15),
                                   amount: 12, name: "Uber Ride")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    link = @draft.document_link.reload
    assert_equal "unlinked", link.status
    assert_nil link.entry_id, "the receipt must not be linked to an unrelated charge"
    assert_equal 0, DocumentLink.where(entry_id: unrelated.id).count,
                 "and the unrelated entry gets no document of its own"
  end

  test "a same-charge entry whose name matches the payee is corroborated" do
    # The identity rule is loose on formatting: "STARBUCKS 1234" and the payee
    # "Starbucks" name the same merchant, so this IS the receipt's charge.
    existing = create_transaction(account: @account, date: Date.new(2026, 9, 16),
                                  amount: 12, name: "STARBUCKS 1234")

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    assert_equal existing.id, @draft.document_link.reload.entry_id
  end

  test "a receipt with no payee falls to review rather than posting" do
    # No payee is no identity signal, so the receipt can neither be corroborated
    # (nothing to match) nor safely minted (there might be an unidentified charge
    # it is evidence of). It falls to review.
    @draft.update!(extracted_data: @draft.extracted_data.merge("payee" => nil))

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    link = @draft.document_link.reload
    assert_equal "unlinked", link.status
    assert_nil link.entry_id
  end

  # --- W3-4: never re-point a document already linked to an entry ------------

  test "the writer does nothing for a document already linked to an entry" do
    # A document already committed to an entry is done. The auto-post must not
    # mint a second entry, and must never STEAL the existing edge by re-pointing
    # the link at a new one.
    other = create_transaction(account: @account, date: @draft.purchase_date, amount: 99, name: "Already linked")
    link = @draft.document_link
    link.link_to_entry!(other)
    assert_equal other.id, link.reload.entry_id

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end

    link.reload
    assert_equal other.id, link.entry_id, "the link must not be stolen or re-pointed"
    assert_equal "linked", link.status
  end

  # --- W3-3: the gate is re-judged inside the lock ---------------------------

  test "the gate is re-judged inside the row lock on the reloaded draft" do
    # A TOCTOU window: the draft's stored witness is invalidated AFTER the job
    # has read the draft but BEFORE it locks the row. A gate judged on the stale,
    # pre-lock read would post money anyway; a gate judged inside the lock on the
    # reloaded draft sees the invalidated witness and refuses.
    original_with_lock = ReceiptImport.instance_method(:with_lock)
    # The value that only a gate evaluated on the RELOADED draft can see: clear
    # the OCR/vision witness in the DB. Captured as a local (the hook's `self` is
    # the draft, not this test).
    extraction = @draft.document_link.extraction
    ReceiptImport.define_method(:with_lock) do |*args, &block|
      extraction.update!(validations: { "totals_agree" => nil })
      original_with_lock.bind(self).call(*args, &block)
    end

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end
    assert_equal "unlinked", @draft.document_link.reload.status
  ensure
    ReceiptImport.define_method(:with_lock, original_with_lock)
  end

  # W3-3 (finding 2): the receipt/bill guard and the household switch are part of
  # the gate too, so they are re-read inside the lock on the reloaded document —
  # not from the stale pre-lock read.
  test "the receipt/bill guard is re-read inside the lock on the reloaded document" do
    original_with_lock = ReceiptImport.instance_method(:with_lock)
    link = @draft.document_link
    ReceiptImport.define_method(:with_lock) do |*args, &block|
      # Re-typed as a BILL in the window after the job's first read but before
      # the lock. A guard read on the stale draft would still auto-post it.
      link.update_columns(source: "bill")
      original_with_lock.bind(self).call(*args, &block)
    end

    assert_no_difference -> { Entry.count } do
      AutoPostReceiptJob.perform_now(@draft.id)
    end
    assert_equal "unlinked", @draft.document_link.reload.status
  ensure
    ReceiptImport.define_method(:with_lock, original_with_lock)
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
