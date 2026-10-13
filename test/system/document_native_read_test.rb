require "application_system_test_case"

# The native read, end to end, through the surfaces that already exist.
#
# Milestone B replaced the wizard with ONE dropzone: a file dropped on the
# Documents page posts to the intake endpoint and its Turbo Stream appends the
# row in place. This drives that journey — minus the paperless stubs and plus
# the native ones: the OCR sidecar stub and the provider double. It is the
# system-level companion to Task 7's DocumentUnderstandingJob tests and Task
# 14's live acceptance run.
class DocumentNativeReadTest < ApplicationSystemTestCase
  # The read's verdict. institution/last4 resolve to the seeded account below
  # (spec N14), so the journey can also assert the prefill reached the draft.
  # §7.5's second witness rides along: the default OCR text below prints the
  # card's four digits, so the last4 hint is genuinely witnessed and the prefill
  # legitimately clears the bar.
  LATTE = {
    "document_class" => "receipt", "institution_name" => "Chase",
    "total" => "4.75", "date" => "2026-09-14", "payee" => "Latte Lane Cafe",
    "currency" => "USD", "card_last4" => "4242",
    "line_items" => [], "transactions" => [],
    "field_confidence" => { "total" => 0.98 }
  }.freeze

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @account = accounts(:depository)
    users(:family_admin).update!(default_account: @account)
    # The read's account resolver (Account::DocumentMatcher) prefills from the
    # AI's institution/last4 hints — seeded here so the draft resolves.
    @account.update!(institution_name: "Chase", last4: "4242", account_network: "visa")

    # Run the native read inline, exactly as ReceiptWizardTest folded the
    # paperless chain, so the whole journey completes inside the request.
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    # The publish's post-commit family fan-out, not the surface under test.
    Family.any_instance.stubs(:sync_later)
  end

  teardown { ActiveJob::Base.queue_adapter = @previous_adapter }

  # The OCR sidecar's success shape plus a provider double returning one
  # receipt verdict — the working seam ReceiptWizardTest established. The
  # brief's `stub_openai_chat` (WebMock on /chat/completions) only bites when a
  # real Provider::Openai is constructed, which needs a configured
  # OPENAI_ACCESS_TOKEN this environment does not have; the registry double is
  # the seam the pipeline actually calls.
  def stub_read(text: "LATTE LANE CAFE\n2026-09-14\nTOTAL 4.75\nVISA ****4242")
    stub_ocr_success(pages: [ { page: 1, text: text, confidence: 0.97, image: "aGk=" } ])
    stub_document_provider(LATTE)
  end

  # The one dropzone (design D2): the bar's picker is a hidden input behind the
  # Add document button; its change posts the file to the intake endpoint and
  # the Turbo Stream appends the row to #documents_grid in place — no
  # navigation. With the inline adapter the read has settled the row before the
  # response is processed, so waiting for the appended row is enough.
  def upload_receipt
    visit documents_path
    assert_selector "input[type='file'][name='document']", visible: :all
    execute_script("document.querySelector(\"input[type='file'][name='document']\").classList.remove('hidden')")
    before = page.all("#documents_grid [id^='document_link_']").size
    attach_file "document", file_fixture("receipts/receipt.png")
    assert_selector "#documents_grid [id^='document_link_']", count: before + 1, wait: 5
  end

  test "an uploaded receipt is read and lands in the archive ready for review" do
    stub_read
    upload_receipt

    link = DocumentLink.order(:created_at).last
    assert_equal "unlinked", link.status, "a settled read is visible, not still 'reading'"
    assert_equal "receipt", link.source, "the class came from the AI, not from a wizard tile"
    assert_equal "ai", link.classified_by
    assert_equal 1, link.receipt_imports.count
    assert_equal BigDecimal("4.75"), link.receipt_imports.first.total_amount
    assert_includes link.extracted_text, "TOTAL 4.75"
    # Spec N14: the hints resolved to the seeded account above the prefill bar.
    assert_equal @account, link.receipt_imports.first.account
  end

  test "the same bytes twice are one document, not two" do
    stub_read
    upload_receipt

    file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png").to_s, "image/png")
    enqueue = ->(l) { DocumentUnderstandingJob.perform_later(l.id) }

    assert_no_difference -> { DocumentLink.count } do
      assert_raises(DocumentLink::Intake::Duplicate) do
        DocumentLink::Intake.call(family: families(:dylan_family), uploader: users(:family_admin),
                                  file: file, enqueue: enqueue)
      end
    end
  end

  test "a document the AI cannot read keeps its bytes and asks for input" do
    stub_request(:post, "#{Ocr.url}/ocr").to_return(status: 422, body: { error: "unreadable" }.to_json)
    upload_receipt

    link = DocumentLink.order(:created_at).last
    assert_equal "queued", link.status
    assert_nil link.extraction, "an unreadable document must not record a verdict"
    assert link.stored_path.present?, "the original bytes must survive an unreadable read"
  end
end
