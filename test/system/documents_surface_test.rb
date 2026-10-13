require "application_system_test_case"

# The Documents surface Milestone B built (design D1–D5): ONE dropzone whose
# landing tile shows in the grid, the one-page type facet, and the per-document
# "what I understood" panel.
#
# The read's own end-to-end (OCR sidecar + provider) is DocumentNativeReadTest;
# this file pins the SURFACE those pieces render. The brief's snippets were
# written before the surface froze — two of its assertions name output that does
# not exist:
#   * the receipt test asserted `entries.provenance.document` on the Documents
#     page, but provenance renders on a transaction's row, never here — the
#     tile's own type label is what the code requires;
#   * the filter test used `check … "statement"`, but the facet is a single-
#     select RADIO group (the "All" chip only clears a type if the group is
#     single-select) and the chip's label is "Statements", not "Statement".
# Where the code and the snippet disagree, this follows the code.
class DocumentsSurfaceTest < ApplicationSystemTestCase
  # The read's verdict. institution/last4 resolve to the seeded depository
  # (spec N14), and the total matches the OCR text below so the two reads agree.
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
    # The read's account resolver (Account::DocumentMatcher) prefills from the
    # AI's institution/last4 hints — seeded so the draft resolves.
    @account.update!(institution_name: "Chase", last4: "4242", account_network: "visa")

    # Run the read inline so the journey completes inside the request and the
    # appended tile is the SETTLED tile (the DocumentNativeReadTest seam).
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    # The post-commit family fan-out, not the surface under test.
    Family.any_instance.stubs(:sync_later)
  end

  teardown { ActiveJob::Base.queue_adapter = @previous_adapter }

  # One dropzone (design D2): a file dropped on the page posts to the one intake
  # endpoint, and its Turbo Stream appends the tile into #documents_grid in
  # place — no navigation. The tile shows what the read produced: its type, its
  # merchant and its amount.
  test "one dropzone takes a receipt and the grid shows the tile it read" do
    stub_read
    visit documents_path

    assert_selector "input[type='file'][name='document']", visible: :all
    before = page.all("#documents_grid [id^='document_link_']").size
    # The picker is a hidden input behind the Add document button; the chosen
    # file's `change` is what uploads it (the same path a real drop takes).
    execute_script("document.querySelector(\"input[type='file'][name='document']\").classList.remove('hidden')")
    attach_file "document", file_fixture("receipts/receipt.png")

    assert_selector "#documents_grid [id^='document_link_']", count: before + 1, wait: 5

    link = DocumentLink.order(:created_at).last
    within "#document_link_#{link.id}" do
      assert_text "Latte Lane Cafe"                    # the merchant the read produced
      assert_text I18n.t("documents.source.receipt")   # typed as a receipt, not asked
      assert_text "12.0"                                # and its amount (BigDecimal#to_s("F"))
    end
    assert_equal "receipt", link.source
    assert_equal "ai", link.classified_by
  end

  # The one-page type facet (design D1): narrowing to Statements drops the
  # receipt/bill tiles from the grid, and the All chip clears it. Assertions are
  # scoped to the grid and use tiles' titles: the tile's type label IS "Receipt",
  # and the facet's chip label is "Receipts & Bills", so an unscoped
  # `assert_no_text "Receipt"` would fail for the wrong reason.
  test "the type facet narrows the grid, and All clears it" do
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement", status: "unlinked", title: "A statement to filter")
    bill_title = document_links(:held_bill).title

    visit documents_path
    within "#documents_grid" do
      assert_text statement.title
      assert_text bill_title
    end

    find("label", text: I18n.t("document_browser.filters.types.statements"), match: :first).click
    within "#documents_grid" do
      assert_text statement.title, wait: 5
      assert_no_text bill_title
    end

    find("label", text: I18n.t("document_browser.filters.types.all"), match: :first).click
    within "#documents_grid" do
      assert_text bill_title, wait: 5
    end
  end

  # The "what I understood" panel (design D4, spec §9): a read document shows
  # the settled class, each field with its confidence, the checks, and the
  # doubts marked. `understood_receipt_link` carries a succeeded extraction with
  # a confident field (payee) and an unsure one (total, below the bar).
  test "the viewer's panel shows what was understood and where the doubts are" do
    link = document_links(:understood_receipt_link)
    visit viewer_document_path(link)

    within "[data-document-understanding]" do
      assert_text I18n.t("documents.understanding.title")

      # what it decided
      assert_text I18n.t("documents.source.receipt")
      assert_text I18n.t("documents.understanding.confidence", percent: 96)

      # what it read, with the doubt marked only on the unsure field
      within "[data-field='total']" do
        assert_text I18n.t("documents.understanding.check_this")
      end
      within "[data-field='payee']" do
        assert_no_text I18n.t("documents.understanding.check_this")
      end

      # the checks and what it became
      assert_text I18n.t("documents.understanding.not_checkable")
      assert_text I18n.t("documents.understanding.state.understood")
    end
  end

  private
    def stub_read(text: "LATTE LANE CAFE\n2026-09-14\nTOTAL 12.00\nVISA 4242")
      stub_ocr_success(pages: [ { page: 1, text: text, confidence: 0.97, image: "aGk=" } ])
      stub_document_provider(RECEIPT)
    end
end
