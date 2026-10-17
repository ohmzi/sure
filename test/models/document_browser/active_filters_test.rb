require "test_helper"

# The filters a person has turned on, as the Documents redesign shows them: one
# removable chip each, and their count on the filter button's badge. Search and
# type have their own controls on the page and sort orders rather than narrows,
# so none of them is a chip.
class DocumentBrowser::ActiveFiltersTest < ActiveSupport::TestCase
  def active(filters, family: :documents, url: "/documents")
    DocumentBrowser::ActiveFilters.new(filters: filters, url: url, family: family, currency: "CAD")
  end

  def query(url) = Rack::Utils.parse_nested_query(URI(url).query.to_s)

  test "nothing on is no chips and a zero badge" do
    filters = active({ search: "coffee", type: [ "statement" ], sort: "oldest" })

    assert_empty filters.chips
    assert_equal 0, filters.count
  end

  test "each status, tag and the merchant is its own chip" do
    filters = active({ status: %w[queued failed], tags: %w[bill], merchant: "FreshMart" })

    assert_equal [ I18n.t("documents.status.queued"), I18n.t("documents.status.failed"), "bill", "FreshMart" ],
                 filters.chips.map(&:label)
    assert_equal 4, filters.count
  end

  test "removing a chip keeps every other filter, the search, the type and the sort" do
    filters = active({ status: %w[queued failed], search: "coffee", type: [ "statement" ], sort: "oldest" })
    queued = filters.chips.find { |chip| chip.label == I18n.t("documents.status.queued") }

    assert_equal(
      { "q" => { "status" => [ "failed" ], "search" => "coffee", "type" => [ "statement" ], "sort" => "oldest" } },
      query(queued.remove_url)
    )
    assert queued.remove_url.start_with?("/documents?")
  end

  test "removing the last filter leaves the bare page" do
    chip = active({ merchant: "FreshMart" }).chips.first

    assert_equal "/documents", chip.remove_url
  end

  test "an amount range is one chip in the family's currency" do
    ten = Money.new(10, "CAD").format
    fifty = Money.new(50, "CAD").format

    assert_equal [ I18n.t("document_browser.filters.chips.amount_between", min: ten, max: fifty) ],
                 active({ amount_min: "10", amount_max: "50" }).chips.map(&:label)
    assert_equal [ I18n.t("document_browser.filters.chips.amount_over", amount: ten) ],
                 active({ amount_min: "10" }).chips.map(&:label)
    assert_equal [ I18n.t("document_browser.filters.chips.amount_under", amount: fifty) ],
                 active({ amount_max: "50" }).chips.map(&:label)

    both = active({ amount_min: "10", amount_max: "50" }).chips.first
    assert_equal({}, query(both.remove_url).fetch("q", {}))
  end

  test "a date range is one chip, and a nonsense date is no chip" do
    chip = active({ date_from: "2026-09-01", date_to: "2026-09-30" }).chips.first

    assert_equal I18n.t("document_browser.filters.chips.date_between",
                        from: I18n.l(Date.new(2026, 9, 1), format: :short),
                        to: I18n.l(Date.new(2026, 9, 30), format: :short)), chip.label
    assert_empty active({ date_from: "soon" }).chips
    assert_empty active({ amount_min: "lots" }).chips
  end

  test "unknown statuses are not chips" do
    assert_empty active({ status: %w[bogus] }).chips
  end

  test "the needs-you link is a chip and counts" do
    filters = active({ attention: "1" })

    assert_equal [ I18n.t("document_browser.filters.chips.needs_you") ], filters.chips.map(&:label)
    assert_equal 1, filters.count
  end

  test "the statements archive's review and extraction facets are chips" do
    filters = active({ review: %w[unmatched], extraction: %w[extraction_failed], merchant: "RBC" },
                     family: :statements, url: "/account_statements")

    assert_equal [ I18n.t("account_statements.status.unmatched"),
                   I18n.t("document_browser.filters.extraction_states.extraction_failed"), "RBC" ],
                 filters.chips.map(&:label)
    assert filters.chips.all? { |chip| chip.remove_url.start_with?("/account_statements") }
  end

  test "reset keeps only the search and the type" do
    filters = active({ status: %w[queued], search: "coffee", type: [ "statement" ], sort: "oldest", attention: "1" })

    assert_equal({ "q" => { "search" => "coffee", "type" => [ "statement" ] } }, query(filters.reset_url))
  end

  test "a type link swaps the type and keeps everything else" do
    filters = active({ status: %w[queued], type: [ "statement" ] })

    assert_equal({ "q" => { "status" => [ "queued" ], "type" => [ "receipt,bill" ] } }, query(filters.type_url("receipt,bill")))
    assert_equal({ "q" => { "status" => [ "queued" ] } }, query(filters.type_url("")))
  end
end
