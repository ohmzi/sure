require "test_helper"

class DS::DialogTest < ViewComponent::TestCase
  # Turbo caches a page as it was left, and Back restores that copy. A drawer or
  # modal fetched into the page came back with it: stray and non-modal if it was
  # still open, opened again if it had been closed.
  test "a drawer fetched into its frame is left out of Turbo's page cache" do
    vc_test_request.headers["Turbo-Frame"] = "drawer"
    render_inline(DS::Dialog.new(frame: "drawer", responsive: true))

    assert_selector "turbo-frame#drawer > dialog[data-turbo-temporary]"
  end

  test "a drawer fetched into a frame of its own is left out of Turbo's page cache" do
    vc_test_request.headers["Turbo-Frame"] = "bulk_transaction_edit_drawer"
    render_inline(DS::Dialog.new(variant: "drawer", frame: "bulk_transaction_edit_drawer"))

    assert_selector "turbo-frame#bulk_transaction_edit_drawer > dialog[data-turbo-temporary]"
  end

  # Visited directly, the drawer is the page, and Back has to bring it back.
  test "a drawer rendered as the page stays in the cache" do
    render_inline(DS::Dialog.new(frame: "drawer", responsive: true))

    assert_selector "turbo-frame#drawer > dialog"
    assert_no_selector "dialog[data-turbo-temporary]"
  end

  test "a modal fetched into the modal frame is left out of Turbo's page cache" do
    vc_test_request.headers["Turbo-Frame"] = "modal"
    render_inline(DS::Dialog.new)

    assert_selector "turbo-frame#modal > dialog[data-turbo-temporary]"
  end

  # The sheet (Documents redesign, 2026-10-16): an iOS bottom sheet below lg —
  # a grabber to drag it down by, anchored to the bottom edge, its own safe-area
  # padding — and a centered panel from lg up. Opened by an event, never on
  # render, so it can live inline in a page.
  test "a sheet is a bottom sheet with a grabber that a page opens on demand" do
    render_inline(DS::Dialog.new(variant: "sheet", auto_open: false, disable_frame: true, id: "filters_sheet")) do |dialog|
      dialog.with_body { "Body" }
    end

    assert_selector "dialog#filters_sheet[data-ds--dialog-sheet-value='true'][data-ds--dialog-auto-open-value='false']"
    assert_selector "dialog[data-action~='sheet:open->DS--dialog#open'][data-action~='sheet:close->DS--dialog#close']"
    assert_selector "dialog [data-ds--dialog-target='grabber']"
    assert_selector "dialog [data-ds--dialog-target='content'].rounded-t-3xl"
    assert_text "Body"
  end

  test "modal and drawer dialogs have no grabber and are not sheets" do
    render_inline(DS::Dialog.new) { |dialog| dialog.with_body { "Body" } }

    assert_no_selector "[data-ds--dialog-target='grabber']"
    assert_selector "dialog[data-ds--dialog-sheet-value='false']"
  end

  # The iOS sheet header: a leading action, the centred title the dialog is
  # labelled by, and a trailing action.
  test "a sheet header centres the title between its two actions" do
    render_inline(DS::Dialog.new(variant: "sheet", auto_open: false, disable_frame: true)) do |dialog|
      dialog.with_sheet_header(title: "Filters", leading: "<a href='/reset'>Reset</a>".html_safe,
                               trailing: "<button type='submit'>Done</button>".html_safe)
    end

    assert_selector "dialog header.grid-cols-3 > div:first-child > a[href='/reset']", text: "Reset"
    assert_selector "dialog header.grid-cols-3 > h2", text: "Filters"
    assert_selector "dialog header.grid-cols-3 > div:last-child > button[type='submit']", text: "Done"
    title_id = page.find("dialog header h2")[:id]
    assert_selector "dialog[aria-labelledby='#{title_id}']"
  end
end
