require "application_system_test_case"

class DocumentBridgeTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @entry = entries(:transaction)
    # Leave exactly one linkable candidate (the upload) so the panel's link
    # action is unambiguous.
    DocumentLink.where(status: "unlinked").delete_all

    # Run jobs inline and stub the native read — the OCR sidecar and the AI
    # provider — so the whole bridge (upload -> read -> unlinked -> link) runs
    # in this process.
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 4.75", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_document_provider
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "upload a receipt, see it, then link it to an entry" do
    visit documents_path

    # Milestone B: the archive's upload card is the one dropzone now. Its picker
    # is a hidden input behind the Add document button; un-hide it so
    # attach_file can set it (the technique the wizard's system tests use), and
    # the change posts the file to the ONE intake endpoint, whose Turbo Stream
    # appends the row in place — no form submit, no navigation.
    assert_selector "input[type='file'][name='document']", visible: :all
    add_document_file(file_fixture("receipts/receipt.png"))

    # The upload flow ran inline: the row exists, has been posted and polled,
    # and is listed as an unlinked candidate on the entry page.
    assert_selector "#documents_grid [id^='document_link_']", text: "receipt.png", wait: 5

    visit transaction_path(@entry)
    within "#document-link-panel" do
      click_button I18n.t("document_link_panel.link")
    end

    # Linking flips the panel action to unlink and files the row against the entry.
    # Ruling 9 (M1): `for_entry.exists?` alone passed even on a dead click — the
    # `linked_receipt` fixture (lunch.pdf) already belongs to @entry and survives
    # setup's delete_all, and the panel renders Unlink for every linked row. Pin
    # the UPLOADED row by its unique filename, and pin that no link candidate is
    # left (setup left the upload as the only one).
    assert_button I18n.t("document_link_panel.unlink")
    # Ruling 10 (M1): the link POST is asynchronous — Turbo submits the form and
    # follows the controller's redirect — so the database read below can race the
    # commit (it read nil on 4 of 15 recorded runs). Wait for the panel to
    # re-render the UPLOADED row as linked — a positive DOM signal that only
    # exists after the POST commits — before reading the database.
    assert_selector :xpath, "//div[@id='document-link-panel']//div[.//span[normalize-space()='receipt.png'] and .//button[normalize-space()='#{I18n.t("document_link_panel.unlink")}']]"
    upload = DocumentLink.find_by(original_filename: "receipt.png")
    assert_equal @entry.id, upload.entry_id, "the uploaded receipt must link to the entry"
    assert_no_button I18n.t("document_link_panel.link")
  end
end
