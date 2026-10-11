# frozen_string_literal: true

# The browser controllers' shared plumbing (M8). Task 4 adds the viewer's
# pass-through params here; the permitted facet list is frozen in one place so
# the two pages can never drift.
module DocumentBrowser
  extend ActiveSupport::Concern

  private
    def document_browser_filters
      params.fetch(:q, {}).permit(
        :search, :sort, :date_from, :date_to, :merchant, :amount_min, :amount_max,
        status: [], tags: [], extraction: [], review: []
      ).to_h.symbolize_keys
    end
end
