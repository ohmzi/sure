require "application_system_test_case"

class DocumentBridgeTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @entry = entries(:transaction)
    # Leave exactly one linkable candidate (the upload) so the panel's link
    # action is unambiguous.
    DocumentLink.where(status: "unlinked").delete_all

    # Run jobs inline and stub only the paperless egress, so the whole bridge
    # (upload -> post -> poll -> unlinked -> link) runs in this process. The
    # thumbnail <img> tags hit DocumentLinksController#file (Ruling M11 (M1): plain img, not a Turbo frame), so #file must be
    # stubbed too (yielded, not returned — Mocha `.returns` never invokes a
    # passed block).
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    # Ruling 8 (M1): the inline adapter cannot enqueue FUTURE jobs
    # (InlineAdapter#enqueue_at raises NotImplementedError in activejob 8.1.3),
    # so the upload job's set(wait:) poll handoff would 500 the POST and strand
    # the row in `processing`. Folding `set` back to an immediate perform keeps
    # the whole bridge in-process, exactly as the comment above intends.
    # Production is untouched — Sidekiq schedules the real wait.
    Paperless::TaskPollJob.stubs(:set).returns(Paperless::TaskPollJob)
    Paperless::Client.any_instance.stubs(:configured?).returns(true)
    Paperless.stubs(:tag_id).returns(1)
    Paperless::Client.any_instance.stubs(:post_document).returns("task-uuid")
    Paperless::Client.any_instance.stubs(:task).returns(
      Paperless::Task.new(status: :success, document_id: 6001, duplicate_of: nil, error_message: nil)
    )
    Paperless::Client.any_instance.stubs(:file).yields(
      "", OpenStruct.new(status: 200, response_headers: { "content-type" => "image/png" })
    )
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "upload a receipt, see it, then link it to an entry" do
    visit documents_path

    attach_file "document", file_fixture("receipts/receipt.png")
    find("form[action='#{documents_path}'] [type='submit']").click

    # The upload flow ran inline: the row exists, has been posted and polled,
    # and is listed as an unlinked candidate on the entry page.
    assert_text "receipt.png", wait: 5

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
