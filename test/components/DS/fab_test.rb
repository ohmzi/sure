require "test_helper"

class DS::FabTest < ViewComponent::TestCase
  # The floating action button (the Quicken Simplifi language, 2026-10-17):
  # one round brand-coloured button over the main content's corner, clear of
  # the phone's bottom bar. A button by default, a link with `href:`.
  test "renders a labelled round button kept over the main content" do
    render_inline(DS::Fab.new(icon: "plus", label: "Add document", aria: { controls: "document_add_sheet" }))

    assert_selector "button[type='button'][aria-label='Add document'][aria-controls='document_add_sheet'].fixed.rounded-full.bg-inverse"
    assert_selector "button[data-controller~='floating-action'] svg"
  end

  test "href renders a link, and a frame targets it" do
    render_inline(DS::Fab.new(icon: "plus", label: "New", href: "/accounts/new", frame: :modal, class: "lg:hidden"))

    assert_selector "a[href='/accounts/new'][data-turbo-frame='modal'][aria-label='New'].lg\\:hidden"
  end
end
