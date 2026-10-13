require "application_system_test_case"

# The money path, end to end, through the surfaces Milestone B built: a receipt
# whose OCR and vision reads agree posts itself, the ledger row says the app
# wrote it, the AI-posted audit filter finds it, and undo takes the entry back
# while the document survives (spec N6).
#
# The class is named `AutoPostSurfaceTest`, not `AutoPostTest`: the pure gate is
# pinned by test/models/auto_post_test.rb under that name, and two top-level
# classes of the same name would reopen one constant.
class AutoPostSurfaceTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  # The read's verdict: institution/last4 resolve to the seeded depository, and
  # the total agrees with the OCR text below (the second witness the gate needs).
  RECEIPT = {
    "document_class" => "receipt", "institution_name" => "Chase",
    "total" => "12.00", "date" => "2026-09-14", "payee" => "Latte Lane Cafe",
    "currency" => "USD", "card_last4" => "4242",
    "line_items" => [], "transactions" => [],
    "field_confidence" => { "total" => 0.98, "date" => 0.97 }
  }.freeze

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @account = accounts(:depository)
    users(:family_admin).update!(default_account: @account)
    @account.update!(institution_name: "Chase", last4: "4242", account_network: "visa")
    Family.any_instance.stubs(:sync_later)

    # The household switch on (its default), made explicit: without it the
    # writer is off and nothing posts.
    Setting.stubs(:auto_post_receipts?).returns(true)

    stub_ocr_success(pages: [ { page: 1, text: "LATTE LANE CAFE\n2026-09-14\nTOTAL 12.00\nVISA 4242",
                                confidence: 0.97, image: "aGk=" } ])
    stub_document_provider(RECEIPT)
  end

  def upload_receipt
    visit documents_path
    execute_script("document.querySelector(\"input[type='file'][name='document']\").classList.remove('hidden')")
    before = page.all("#documents_grid [id^='document_link_']").size
    attach_file "document", file_fixture("receipts/receipt.png")
    # The upload is an async fetch; wait for its Turbo Stream to append the
    # placeholder tile, so the read is ENQUEUED before the queue is drained.
    assert_selector "#documents_grid [id^='document_link_']", count: before + 1, wait: 5
  end

  # Drains the queue to post the receipt, then returns [entry, link].
  #
  # `perform_enqueued_jobs` is called TWICE on purpose — not an inline adapter.
  # `DocumentUnderstandingJob` enqueues `AutoPostReceiptJob` BEFORE its
  # `resolve_account` resolves the draft's account, so under an inline adapter
  # the writer would run with no account and refuse. The test adapter stores the
  # writer when it is enqueued and performs it on the next drain, by which point
  # the read has finished and the account is set — the same ordering the real
  # Sidekiq queues give in production.
  def post_receipt
    upload_receipt
    perform_enqueued_jobs  # the read (DocumentUnderstandingJob)
    perform_enqueued_jobs  # the writer the read enqueued (AutoPostReceiptJob)

    link = DocumentLink.order(:created_at).last
    [ @account.entries.find_by(external_id: "document:#{link.id}"), link ]
  end

  test "a receipt that clears the gate posts itself, and the ledger says the app wrote it" do
    entry, link = post_receipt

    assert_not_nil entry, "the receipt must post itself when every gate condition holds"
    assert_not_nil entry.ai_posted_at, "the write must carry the machine's mark"
    assert_equal "document", entry.source
    assert_equal BigDecimal("12.00"), entry.amount
    assert_equal Date.new(2026, 9, 14), entry.date

    link.reload
    assert_equal "linked", link.status, "the provenance edge must be recorded"
    assert_equal entry.id, link.entry_id

    # The transaction's own page says the app wrote it, and links the document.
    visit transaction_path(entry)
    within "[data-auto-post]" do
      assert_text I18n.t("entries.auto_post.badge")
      assert_selector "a[href='#{viewer_document_path(link)}']"
    end

    # The audit filter narrows the ledger to exactly the rows the app wrote.
    visit transactions_path
    find("#transaction-filters-button").click
    within "#transaction-filters-menu" do
      find("[role='tab'][data-id='ai_posted_filter']").click
      check "q_ai_posted"
      click_button I18n.t("transactions.searches.menu.apply")
    end
    within "##{ActionView::RecordIdentifier.dom_id(entry)}" do
      assert_text I18n.t("entries.auto_post.badge")
    end
  end

  test "undo removes the entry the app wrote, and the document survives" do
    entry, link = post_receipt
    entry_id = entry.id
    link_id = link.id
    row_id = "##{ActionView::RecordIdentifier.dom_id(entry)}"

    # Undo is a ledger-row affordance (the row carries the badge and the button).
    visit transactions_path
    within row_id do
      click_button I18n.t("entries.auto_post.undo")
    end
    assert_selector "#confirm-dialog", visible: true
    within "#confirm-dialog" do
      click_button I18n.t("entries.auto_post.undo")
    end

    # The DELETE is an async Turbo request; wait for its redirect to land (the
    # row leaves) before reading the database.
    assert_no_selector row_id, wait: 5
    assert_nil Entry.find_by(id: entry_id), "undo must remove the entry the app wrote"

    surviving = DocumentLink.find_by(id: link_id)
    assert_not_nil surviving, "the document must survive the undo"
    assert_nil surviving.deleted_at, "and stay in the archive"
    assert surviving.auto_post_undone?,
           "and remember the reversal, so a reprocess never silently re-posts"
  end
end
