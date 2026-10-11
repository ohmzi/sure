# frozen_string_literal: true

# The documents page's scope builder (M8 locked decision 2). One place turns
# the browser's params into SQL; the viewer's prev/next recomputes through the
# SAME object, so the walk can never desync from the list. Nothing here calls
# paperless (locked decision 4).
class DocumentLink::Search
  def initialize(family:, filters: {}, sources: nil)
    @family = family
    @filters = filters.symbolize_keys
    @sources = Array(sources).presence
  end

  def relation
    scope = @family.document_links.includes(:account_statement, :receipt_imports)
    scope = scope.where(source: @sources) if @sources
    scope.order(created_at: :desc)
  end
end
