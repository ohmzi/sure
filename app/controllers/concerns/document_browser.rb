# frozen_string_literal: true

# The browser controllers' shared plumbing (M8). The permitted facet list is
# frozen in one place so the two pages can never drift.
module DocumentBrowser
  extend ActiveSupport::Concern

  private
    def document_browser_filters
      # (Ruling M8-C6, 2026-10-11 close-out) `?q=coffee` (or `q[]=`) sends a
      # scalar where the facet hash belongs; wrapping the fetched value empty
      # keeps both GET surfaces a 200 instead of a 500 out of #permit (the
      # task-2 finding's one-line shape guard).
      q = params.fetch(:q, {})
      q = ActionController::Parameters.new unless q.is_a?(ActionController::Parameters)
      q.permit(
        :search, :sort, :date_from, :date_to, :merchant, :amount_min, :amount_max, :attention, :duplicates,
        status: [], tags: [], extraction: [], review: [], type: []
      ).to_h.symbolize_keys
    end

    # The viewer URL carries the index's query string (the rows are built with
    # it), so prev/next recompute over the same filtered list.
    # The walk keeps the list's filters; the transaction a viewer was opened
    # from belongs to that one document, not its neighbours.
    def document_browser_viewer_params
      request.query_parameters.except("entry_id")
    end
end
