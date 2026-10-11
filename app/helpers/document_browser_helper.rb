# frozen_string_literal: true

# The document browser's filter-form options (M8 Task 5). The browser's
# partials render in the view context rather than the component's, so the
# option builders live in a helper both can reach.
module DocumentBrowserHelper
  # The sort select's options, from the one shared sort vocabulary (locked
  # decision 5). The first entry ("newest") is the browser's default, so an
  # unsubmitted select shows the same order the empty query returns.
  def document_browser_sort_options
    DocumentLink::Search::SORTS.map do |sort|
      [ t("document_browser.filters.sorts.#{sort}"), sort ]
    end
  end
end
