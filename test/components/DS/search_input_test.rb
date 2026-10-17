require "test_helper"

class DS::SearchInputTest < ViewComponent::TestCase
  # The filled field (Documents redesign): the iOS search field — a filled,
  # borderless, rounded well — keeping the 16px base font so iOS never zooms.
  test "the filled variant is a borderless rounded well" do
    render_inline(DS::SearchInput.new(variant: :filled, name: "q[search]", placeholder: "Search", id: "q_search"))

    assert_selector "input#q_search[type='search'][name='q[search]'].rounded-xl.bg-surface-inset.text-base"
    assert_no_selector "input.border"
  end

  test "an unknown variant is refused" do
    assert_raises(ArgumentError) { DS::SearchInput.new(variant: :bogus) }
  end
end
