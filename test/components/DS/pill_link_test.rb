require "test_helper"

class DS::PillLinkTest < ViewComponent::TestCase
  test "renders a link with the shared pill shape and a touch-sized target" do
    render_inline(DS::PillLink.new(text: "Review 2 duplicate groups", href: "/documents?q%5Bduplicates%5D=1"))

    link = page.find("a", text: "Review 2 duplicate groups")
    assert_equal "/documents?q%5Bduplicates%5D=1", link[:href]
    %w[rounded-full bg-container text-link focus-ring pointer-coarse:h-11].each do |token|
      assert_includes link[:class], token
    end
  end

  test "passes data and aria attributes through to the link" do
    render_inline(DS::PillLink.new(text: "Show them", href: "/documents", data: { turbo_frame: "_top" },
                                   aria: { label: "Show the documents that need attention" }))

    link = page.find("a", text: "Show them")
    assert_equal "_top", link["data-turbo-frame"]
    assert_equal "Show the documents that need attention", link["aria-label"]
  end
end
