# frozen_string_literal: true

# The documents page's scope builder (M8 locked decision 2). One place turns
# the browser's params into SQL; the viewer's prev/next recomputes through the
# SAME object, so the walk can never desync from the list. Nothing here calls
# paperless (locked decision 4).
class DocumentLink::Search
  # The one sort vocabulary both pages share (M8 locked decision 5).
  # AccountStatement::Search aliases it, so the two selects can never drift.
  SORTS = %w[newest oldest document_date name].freeze

  # The derived "document date" (M8 locked decision 5): the understood draft's
  # parsed purchase date when there is one, else the upload date. ISO text, so
  # the lexicographic comparison is chronological; a parsed date that is not
  # YYYY-MM-DD is ignored rather than allowed to poison the range or the sort.
  # This expression is the sort/range authority — the row's displayed date
  # mirrors it in Ruby.
  DOCUMENT_DATE_SQL = <<~SQL.squish.freeze
    COALESCE(
      (SELECT ri.extracted_data->>'date'
       FROM imports ri
       WHERE ri.document_link_id = document_links.id
         AND ri.type = 'ReceiptImport'
         AND ri.understanding_state = 'understood'
         AND ri.extracted_data->>'date' ~ '\\d{4}-\\d{2}-\\d{2}'
       ORDER BY ri.created_at DESC
       LIMIT 1),
      to_char(document_links.created_at, 'YYYY-MM-DD')
    )
  SQL

  def initialize(family:, filters: {}, sources: nil)
    @family = family
    @filters = filters.symbolize_keys
    @sources = Array(sources).presence
  end

  def relation
    scope = @family.document_links.includes(:account_statement, :receipt_imports)
    scope = scope.where(source: @sources) if @sources
    scope = scope.merge(DocumentLink.search(@filters[:search])) if @filters[:search].present?
    scope = scope.where("#{DOCUMENT_DATE_SQL} >= ?", date_from.iso8601) if date_from
    scope = scope.where("#{DOCUMENT_DATE_SQL} <= ?", date_to.iso8601) if date_to
    scope.order(order_clause)
  end

  private
    # Invalid dates are ignored (M8 Task 5): a half-typed or junk value drops
    # the bound instead of raising out of the page.
    def date_from = parsed_date(@filters[:date_from])
    def date_to = parsed_date(@filters[:date_to])

    def parsed_date(raw)
      Date.iso8601(raw.to_s.strip)
    rescue ArgumentError
      nil
    end

    def sort_key = @filters[:sort].to_s.presence_in(SORTS) || "newest"

    def order_clause
      case sort_key
      when "oldest" then { created_at: :asc }
      when "document_date" then Arel.sql("#{DOCUMENT_DATE_SQL} DESC, document_links.created_at DESC")
      when "name" then Arel.sql("LOWER(COALESCE(NULLIF(document_links.title, ''), document_links.original_filename)) ASC, document_links.created_at DESC")
      else { created_at: :desc }
      end
    end
end
