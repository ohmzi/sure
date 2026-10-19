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
    assert_selector "dialog [data-ds--dialog-target='content'].rounded-t-\\[2rem\\]"
    assert_text "Body"
  end

  # The owner's rule (2026-10-17): every popup on a phone is the same bottom
  # sheet. Modals and drawers keep their own shape from lg up, and are not
  # opened on demand (no `sheet:open`), but below lg they rise from the bottom
  # edge with the grabber like any sheet.
  test "modal and drawer dialogs are bottom sheets on a phone and keep their shape from lg" do
    render_inline(DS::Dialog.new) { |dialog| dialog.with_body { "Body" } }
    assert_selector "dialog[data-ds--dialog-sheet-value='false']"
    assert_selector "dialog [data-ds--dialog-target='grabber'].lg\\:hidden"
    assert_selector "dialog > div.items-end.lg\\:items-center"
    assert_selector "dialog [data-ds--dialog-target='content'].rounded-t-\\[2rem\\].lg\\:rounded-\\[1\\.75rem\\]"

    render_inline(DS::Dialog.new(variant: "drawer")) { |dialog| dialog.with_body { "Body" } }
    assert_selector "dialog [data-ds--dialog-target='grabber']"
    assert_selector "dialog > div.items-end.lg\\:justify-end"
    assert_selector "dialog [data-ds--dialog-target='content'].rounded-t-\\[2rem\\].lg\\:h-full"
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
