require "application_system_test_case"

# The viewer modal's browser journey (M8 Task 4): a row opens the native
# viewer in the #modal Turbo frame, next walks the filtered list, Escape
# closes; a photo opens the lightbox and click toggles its zoom.
class DocumentBrowserTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)

    # The M1 harness (document_bridge_test.rb): only the paperless egress is
    # stubbed, so the whole flow runs in this process. The rows render
    # thumbnails through DocumentLinksController#file (plain <img>, not a Turbo
    # frame), and the viewer loads its frame from the same proxy — #file must be
    # stubbed too (yielded, not returned — Mocha `.returns` never invokes a
    # passed block).
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    Paperless::TaskPollJob.stubs(:set).returns(Paperless::TaskPollJob)
    Paperless::Client.any_instance.stubs(:configured?).returns(true)
    Paperless::Client.any_instance.stubs(:file).yields(
      "", OpenStruct.new(status: 200, response_headers: { "content-type" => "image/png" })
    )
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "a row opens the viewer modal, next walks the list, escape closes" do
    # Pin the order: fixtures share load timestamps, and the walk order is the
    # thing under test.
    unlinked = document_links(:unlinked_receipt)
    linked = document_links(:linked_receipt)
    unlinked.update_columns(created_at: 2.days.ago)
    linked.update_columns(created_at: 1.day.ago) # linked is newer -> next from it is unlinked

    visit documents_path

    # (adapted 2026-10-11, Task 4) `click_on linked.title` is ambiguous inside
    # the row: the thumbnail link carries the same title as its img alt, and
    # Capybara matches links by a descendant img's alt. The title link is the
    # text-bearing one.
    within "#document_link_#{linked.id}" do
      find("a", text: linked.title).click
    end
    assert_selector "#modal dialog[open]"
    assert_selector "iframe[src='#{file_document_path(linked, kind: "original")}']"

    click_on I18n.t("document_browser.viewer.next") # swaps the frame to the neighbour
    # (repaired 2026-10-11, dispatchability check) `unlinked_receipt` is image/png, so
    # the viewer renders its LIGHTBOX branch; the iframe assertion could never pass.
    assert_selector "img[src='#{file_document_path(unlinked, kind: "original")}']"

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
  end

  test "a photo opens the lightbox and click toggles zoom" do
    visit documents_path
    within "#document_link_#{document_links(:unlinked_receipt).id}" do
      find("a", text: document_links(:unlinked_receipt).title).click
    end
    assert_selector "img[data-document-viewer-target='image']"

    find("[data-document-viewer-target='image']").click
    assert_equal "scale(2)", evaluate_script("document.querySelector(\"[data-document-viewer-target='image']\").style.transform")
  end
end
