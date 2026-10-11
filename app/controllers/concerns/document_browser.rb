# frozen_string_literal: true

# The browser controllers' shared plumbing (M8). The permitted facet list is
# frozen in one place so the two pages can never drift.
module DocumentBrowser
  extend ActiveSupport::Concern

  private
    def document_browser_filters
      params.fetch(:q, {}).permit(
        :search, :sort, :date_from, :date_to, :merchant, :amount_min, :amount_max,
        status: [], tags: [], extraction: [], review: []
      ).to_h.symbolize_keys
    end

    # The viewer URL carries the index's query string (the rows are built with
    # it), so prev/next recompute over the same filtered list.
    def document_browser_viewer_params
      request.query_parameters
    end
end
