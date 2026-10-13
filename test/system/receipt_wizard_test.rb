require "application_system_test_case"

# The receipt intake journey. It was the wizard's file (Milestone B's Task 2
# deletes the wizard): the two-row New popup and its step-2 drop screen are
# gone, replaced by ONE dropzone on the Documents page. The subjects are
# unchanged — a receipt uploaded through the UI becomes a reviewable draft, and
# a settled draft reviews and publishes — only the route through the UI changed.
class ReceiptWizardTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @account = accounts(:depository)
    users(:family_admin).update!(default_account: @account)
    # The read's account resolver (Account::DocumentMatcher) prefills this
    # account from the AI's institution/last4 hints, so the journey can assert it.
    @account.update!(institution_name: "Chase", last4: "4242", account_network: "visa")
    # NO `DocumentLink.where(status: "unlinked").delete_all` here (M1's
    # document_bridge_test line): that line belongs to the entry-page link panel
    # this suite never touches, and it would delete the settled `unlinked_receipt`
    # row that `imports(:receipt_draft)` points at (the imports FK nullifies the
    # draft's document_link_id), breaking the second journey's seed.

    # Run jobs inline and stub the native read — the OCR sidecar and the AI
    # provider — so the whole journey (dropzone intake -> read -> settled draft)
    # runs in this process.
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 4.75", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_document_provider
    # The inline adapter cannot enqueue FUTURE jobs, and Import#publish's
    # post-commit `family.sync_later` fan-out enqueues them deep inside Sync's
    # finalization. The family sync fan-out is not the surface under test — the
    # reviewed publish's money write is; production is untouched (Sidekiq runs
    # the real sync).
    Family.any_instance.stubs(:sync_later)
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  # The one dropzone (design D2): the bar's picker is a hidden input behind the
  # Add document button; its change posts the file to the intake endpoint and
  # the Turbo Stream appends the row to #documents_grid in place — no
  # navigation, no wizard screen. The New popup's single "Add a document" row
  # leads here; that link is pinned by accounts_controller_test, so this journey
  # starts on the Documents page itself (the documents_intake_test pattern).
  def upload_receipt
    visit documents_path
    assert_selector "input[type='file'][name='document']", visible: :all
    execute_script("document.querySelector(\"input[type='file'][name='document']\").classList.remove('hidden')")
    before = page.all("#documents_grid [id^='document_link_']").size
    attach_file "document", file_fixture("receipts/receipt.png")
    assert_selector "#documents_grid [id^='document_link_']", count: before + 1, wait: 5
  end

  test "a receipt dropped on the archive becomes a reviewable draft" do
    # Milestone B (design D2): the two-row wizard is gone. A receipt goes in
    # through the ONE dropzone, the Turbo Stream appends its row in place, and
    # the inline read settles it as a reviewable draft — no step 3, no page
    # change.
    upload_receipt

    draft = ReceiptImport.order(:created_at).last
    assert_equal @account, draft.account
    # The inline read settles the draft during the POST, so the appended tile
    # already carries the review state — and the Review affordance itself is now
    # reached from the document (the viewer the tile opens; Milestone B Task 4),
    # not from the tile.
    assert_equal "understood", draft.understanding_state
    within "#document_link_#{draft.document_link.id}" do
      assert_text I18n.t("document_browser.tile.states.review")
      find("a", match: :first).click
    end
    assert_selector "a[href='#{import_path(draft)}'][title='#{I18n.t("imports.receipt_import.review_details")}']"
  end

  test "a receipt from a member with no default account still becomes a reviewable draft" do
    # The native read settles the draft and resolves its account from the AI's
    # hints; the dropzone never asks at a step 3, so a member's drop always ends
    # as a reviewable draft on the archive.
    sign_in users(:family_member)
    upload_receipt

    draft = ReceiptImport.order(:created_at).last
    assert_equal @account, draft.account
    assert_equal "understood", draft.understanding_state
  end

  test "a settling draft flips its tile in place, and the viewer carries the review affordance" do
    # (M8 Task 9, Ruling M8-L1 decision 3; Milestone B Task 4) The archive tile
    # re-renders in place when the draft's understanding settles — no manual
    # reload. The tile is purely visual now, so the flip is its state; the
    # draft's Review affordance is reached from the document itself.
    draft = imports(:receipt_draft)
    link = draft.document_link
    visit documents_path
    # The seeded link is settled (`unlinked`) while its draft still awaits OCR,
    # so the tile carries no review state yet.
    within "#document_link_#{link.id}" do
      assert_text I18n.t("documents.status.unlinked")
    end

    # Settle outside the browser: stage the link's bytes and run the native
    # read, which settles the draft and broadcasts the replaced tile.
    link.update_columns(status: "queued",
                        stored_path: DocumentLink::Staging.write(io: StringIO.new("PNG"), id: link.id))
    DocumentUnderstandingJob.perform_now(link.id)
    # The job mutated the database, not this in-memory copy: reload so the
    # re-broadcast below renders the settled tile, not the pre-read one.
    link.reload

    # The stream subscription may still be connecting on a fast machine, and the
    # tile replace is idempotent: re-broadcast until the flipped tile lands.
    page.document.synchronize(Capybara.default_max_wait_time) do
      unless page.has_selector?("#document_link_#{link.id}", text: I18n.t("document_browser.tile.states.review"))
        link.reload
        link.broadcast_row_update!
        raise Capybara::ExpectationNotMet, "the tile has not flipped to the review state yet"
      end
    end

    within "#document_link_#{link.id}" do
      assert_text I18n.t("document_browser.tile.states.review")
      assert_no_text I18n.t("documents.status.unlinked")
    end

    # The Review affordance itself lives in the viewer the tile opens.
    find("#document_link_#{link.id} a", match: :first).click
    assert_selector "a[href='#{import_path(draft)}'][title='#{I18n.t("imports.receipt_import.review_details")}']"
  end

  test "a settled receipt reviews and publishes into one expense" do
    # Seed the receipt_draft fixture directly (its document_link row survives
    # setup — see the F10 repair above), stage its bytes and run the native read
    # so the draft settles through the real pipeline.
    draft = imports(:receipt_draft)
    link = draft.document_link
    link.update_columns(status: "queued",
                        stored_path: DocumentLink::Staging.write(io: StringIO.new("PNG"), id: link.id))
    DocumentUnderstandingJob.perform_now(link.id)
    draft.reload

    # (Ruling M7-L4, 2026-10-11) The plan's fence navigated the archive card's
    # "Review details" affordance (`documents_path(source: "receipt,bill")` +
    # `imports.receipt_import.review_details`) — but that affordance is Task 9
    # material and moved to M8 with the archive redesign, so it never landed in
    # M7 (RED on the fenced form: `Translation missing:
    # en.imports.receipt_import.review_details` — the M8 plan's Task 2 owns the
    # key now). The publish acceptance itself is unchanged: reach the reviewed
    # screen through the route the wizard ends on (decision 11 — the review
    # page), which is the surface under test here.
    visit import_path(draft)

    assert_text I18n.t("imports.receipt_import.total")
    click_on I18n.t("imports.receipt_import.publish"), wait: 10

    # The publish is a Turbo POST; Task 7's partial renders the publish button
    # only while `publishable?`, so its disappearance is the page-level
    # post-publish signal. But this environment's driver has raced this shape
    # before (M1 Ruling 10: a bare DB read after a Turbo click read nil on 4 of
    # 15 runs — reproduced here before the sync below was added: the click
    # returns before the POST commits), so the READ itself is synced too — the
    # repo's own pattern (release_highlights_test.rb:36-41), which the plan's
    # fence N1 note cites.
    assert_no_button I18n.t("imports.receipt_import.publish")

    entry = nil
    page.document.synchronize do
      # (Task 8) The reviewed publish mints the DOCUMENT identity — the link id,
      # not paperless_document_id (a column Task 12 deletes).
      entry = Entry.find_by(external_id: "document:#{draft.document_link.id}")
      raise Capybara::ElementNotFound, "the reviewed publish is not saved yet" unless entry
    end

    assert_equal "document", entry.source
  end
end
