require "test_helper"

class DS::SearchInputTest < ViewComponent::TestCase
  # The filled field (Documents redesign): an outlined pill on the container
  # colour, keeping the 16px base font so iOS never zooms.
  test "the filled variant is an outlined pill" do
    render_inline(DS::SearchInput.new(variant: :filled, name: "q[search]", placeholder: "Search", id: "q_search"))

    assert_selector "input#q_search[type='search'][name='q[search]'].rounded-full.border.bg-container.text-base"
  end

  test "an unknown variant is refused" do
    assert_raises(ArgumentError) { DS::SearchInput.new(variant: :bogus) }
  end
end
