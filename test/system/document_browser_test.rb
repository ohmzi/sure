require "application_system_test_case"

# The viewer modal's browser journey (M8 Task 4): a row opens the native
# viewer in the #modal Turbo frame, next walks the filtered list, Escape
# closes; a photo opens the lightbox and click toggles its zoom.
class DocumentBrowserTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
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

  # --- M8 Task 8 — the acceptance journey -----------------------------------

  test "the receipts page browses, searches, filters and opens the viewer from the main chrome" do
    visit root_path
    click_link I18n.t("layouts.application.nav.documents") # the main sidebar entry
    assert_current_path documents_path
    assert_no_selector "#settings-nav-container"           # never the settings chrome

    # (repaired 2026-10-11, verifier F9) search narrows the list. DS::SearchInput
    # renders type="search", and auto_submit_form_controller.js resolves search
    # inputs to the BLUR trigger (a 500ms debounce, then requestSubmit) — fill_in
    # alone never submits. Blur explicitly (tab), then assert a row that does NOT
    # match has LEFT the page: "Water bill" is listed before, gone after, so a
    # no-op search cannot pass this. Blurring here also syncs the list before the
    # row click below, so the click never blurs the field out from under an
    # in-flight modal request.
    assert_text document_links(:held_bill).title                 # listed pre-filter
    fill_in "q[search]", with: "coffee"
    find("#q_search").send_keys(:tab)                            # Trigger blur to submit form (transactions_test.rb:37's precedent)
    assert_text document_links(:unlinked_receipt).title          # the match ("Coffee receipt") stays
    assert_no_text document_links(:held_bill).title              # and the non-match leaves

    # open the viewer from a row and close it
    # (adapted 2026-10-11, Task 8 — the fence's `click_on title` is ambiguous,
    # the Task 4 precedent: the thumbnail link carries the same title as its img
    # alt. The title link is the text-bearing one.)
    within "#document_link_#{document_links(:unlinked_receipt).id}" do
      find("a", text: document_links(:unlinked_receipt).title).click
    end
    assert_selector "turbo-frame#modal dialog[open]"
    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
  end

  test "the type facet is single-select — the All segment clears a chosen type" do
    # (Review ruling 1) The three chips used to be independent checkboxes, so
    # from a filtered state All submitted alongside the still-checked type and
    # visibly did nothing. Each segment is now a link to exactly one type, so
    # All genuinely clears the facet — proved end to end here.
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement", title: "Statement to filter")

    visit documents_path(q: { type: [ "statement" ] })
    assert_no_text document_links(:held_bill).title # narrowed to statements

    click_link I18n.t("document_browser.filters.types.all")
    assert_text document_links(:held_bill).title, wait: 5
  end

  # --- the Documents redesign (2026-10-16): the Filters sheet ----------------

  test "the filters sheet applies on Show results, and the chip it leaves takes it off" do
    visit documents_path
    assert_text document_links(:linked_receipt).title

    find("button[aria-controls='document_filters_sheet']").click
    within "dialog#document_filters_sheet[open]" do
      find("label", text: I18n.t("documents.status.queued")).click
      click_on I18n.t("document_browser.filters.show_results")
    end

    assert_no_text document_links(:linked_receipt).title, wait: 5
    assert_text document_links(:held_bill).title
    assert_selector "[data-filter-count]", text: "1"

    within "nav[aria-label='#{I18n.t("document_browser.filters.chips.label")}']" do
      find("a", text: I18n.t("documents.status.queued")).click
    end
    assert_text document_links(:linked_receipt).title, wait: 5
    assert_no_selector "[data-filter-count]"
  end

  test "closing the filters sheet without applying puts its fields back" do
    visit documents_path

    find("button[aria-controls='document_filters_sheet']").click
    within "dialog#document_filters_sheet[open]" do
      find("label", text: I18n.t("documents.status.queued")).click
      assert find("input[value='queued']", visible: :all).checked?
    end
    page.send_keys(:escape)
    assert_no_selector "dialog#document_filters_sheet[open]", wait: 2

    # (waits for the close event's discard, which follows the slide-away)
    assert_selector "dialog#document_filters_sheet input[value='queued']:not(:checked)", visible: :all
    assert_text document_links(:linked_receipt).title # nothing was applied
  end

  test "the floating + opens the add sheet, and Cancel slides it away" do
    visit documents_path

    find("button[aria-controls='document_add_sheet']").click
    within "dialog#document_add_sheet[open]" do
      assert_text I18n.t("documents.intake_bar.scan")
      assert_text I18n.t("documents.intake_bar.photos")
      assert_text I18n.t("documents.intake_bar.choose_file")
      assert_text I18n.t("documents.intake_bar.currency_label")
      click_on I18n.t("documents.intake_bar.cancel")
    end
    assert_no_selector "dialog#document_add_sheet[open]", wait: 2
  end

  test "the statements vault is a first-class page with its facets" do
    # (Milestone B, design D1) The vault is no longer a sidebar destination —
    # one Documents entry — but it survives for reconciliation, still on the
    # main chrome, reached from the account tab's "Open inbox".
    statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family), account: accounts(:depository),
      file: Rack::Test::UploadedFile.new(file_fixture("receipts/statement.pdf"), "application/pdf")
    )
    visit account_statements_path
    assert_current_path account_statements_path
    assert_no_selector "#settings-nav-container"
    assert_text statement.filename

    # The same filter button and sheet, with the archive's own facets.
    find("button[aria-controls='document_filters_sheet']").click
    within "dialog#document_filters_sheet[open]" do
      # Section labels are uppercased by CSS.
      assert_text(/#{I18n.t("document_browser.filters.review")}/i)
      assert_text(/#{I18n.t("document_browser.filters.extraction")}/i)
    end
  end
end
