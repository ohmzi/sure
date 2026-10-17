# frozen_string_literal: true

# The documents page's scope builder (M8 locked decision 2). One place turns
# the browser's params into SQL; the viewer's prev/next recomputes through the
# SAME object, so the walk can never desync from the list. Nothing here leaves
# the database (locked decision 4).
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

  # The understood draft's total, castable-only (the regex is the cast guard:
  # a non-numeric value must never raise mid-query). Latest draft wins.
  # (M8 Task 7, locked decision 7) A refund/negative total does not match any
  # amount filter — the guard admits digits only — and a row with no draft at
  # all yields NULL, so an amount filter can never return it.
  # (deviation 2026-10-11, Task 7) the source writes `\\.` because the
  # unquoted heredoc would otherwise eat the backslash and leave a wildcard
  # dot — the same repair the repo's DOCUMENT_DATE_SQL needed.
  EXTRACTED_TOTAL_SQL = <<~SQL.squish.freeze
    (SELECT ri.extracted_data->>'total' FROM imports ri
      WHERE ri.document_link_id = document_links.id
        AND ri.type = 'ReceiptImport'
        AND ri.extracted_data->>'total' ~ '^[0-9]+(\\.[0-9]+)?$'
      ORDER BY ri.created_at DESC LIMIT 1)
  SQL

  def initialize(family:, filters: {}, sources: nil)
    @family = family
    @filters = filters.symbolize_keys
    @sources = Array(sources).presence
  end

  def relation
    # Tombstones have left the archive: the grid, the strip's filter and the
    # viewer's prev/next all read through this relation, so one `not_deleted`
    # here hides a soft-deleted document from every one of them (spec N9).
    @scope = @family.document_links.not_deleted.includes(:account_statement, :receipt_imports)
    @scope = @scope.where(source: @sources) if @sources
    @scope = @scope.where(source: type_filters) if type_filters.any?
    @scope = @scope.where(status: status_filters) if status_filters.any?
    @scope = @scope.where(id: DocumentLink.needs_attention(@family).select(:id)) if @filters[:attention].present?
    # One representative per duplicate group: opening it shows the other copies
    # beside it in the viewer's duplicate panel.
    @scope = @scope.where(id: DocumentLink.duplicate_representative_ids(@family)) if @filters[:duplicates].present?
    @scope = @scope.merge(DocumentLink.search(@filters[:search])) if @filters[:search].present?
    @scope = @scope.where("#{DOCUMENT_DATE_SQL} >= ?", date_from.iso8601) if date_from
    @scope = @scope.where("#{DOCUMENT_DATE_SQL} <= ?", date_to.iso8601) if date_to
    @scope = merchant_matching(@filters[:merchant])
    @scope = amount_between(@filters[:amount_min], @filters[:amount_max])
    @scope = @scope.where("tags && ARRAY[?]::text[]", tag_filters) if tag_filters.any?
    @scope.order(order_clause)
  end

  private
    attr_reader :scope

    # The status facet (M8 Task 9, Ruling M8-L2): the row's own status
    # vocabulary, so the owner can genuinely ask "show me what is still
    # processing". Unknown tokens are dropped, never widened; a cleared
    # selection filters nothing.
    def status_filters = Array(@filters[:status]) & DocumentLink::STATUSES

    # The type facet (Milestone B, design D1): the one-page type filter. Each
    # chip's value is validated against DocumentLink::SOURCES the way the old
    # top-level source facet was — comma-joined tokens split, unknown tokens
    # dropped, a cleared selection (or the "All" chip's `all`) filtering
    # nothing. This is what makes "Receipts & Bills" one chip (value
    # "receipt,bill").
    def type_filters
      Array(@filters[:type]).flat_map { |value| value.to_s.split(",") }.map(&:strip).uniq
                             .select { |source| DocumentLink::SOURCES.include?(source) }
    end

    # The Merchant / Amount facet (M8 Task 7, locked decision 7): documents
    # read the understood draft's extracted payee/total — never an external
    # call (locked decision 4). Local, like every other filter here.
    def merchant_matching(term)
      return scope if term.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term.to_s.strip)}%"
      scope.where(<<~SQL.squish, p: pattern)
        EXISTS (SELECT 1 FROM imports ri
                 WHERE ri.document_link_id = document_links.id
                   AND ri.type = 'ReceiptImport'
                   AND ri.extracted_data->>'payee' ILIKE :p)
      SQL
    end

    # The amount range casts only through EXTRACTED_TOTAL_SQL's regex guard,
    # so a junk or absent total never reaches ::numeric (never a 500 on a bad
    # cast). A bound that does not parse is dropped; both junk means the
    # amount filter is ignored entirely.
    # (deviation 2026-10-11, Task 7) the pins ride on NAMED binds: the guard
    # regex's `?` quantifier is otherwise counted as a `?` bind placeholder by
    # sanitize_sql_array ("wrong number of bind variables"), so the fence's
    # positional form cannot work alongside the pinned regex.
    def amount_between(min, max)
      min, max = parse_amount(min), parse_amount(max)
      return scope if min.nil? && max.nil?

      sql = "#{EXTRACTED_TOTAL_SQL}"
      conditions = [ "#{sql} IS NOT NULL" ]
      conditions << "#{sql}::numeric >= :min" if min
      conditions << "#{sql}::numeric <= :max" if max
      scope.where(conditions.join(" AND "), min: min, max: max)
    end

    def parse_amount(raw)
      return nil if raw.blank?

      BigDecimal(raw.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end

    # The tag facet (M8 Task 6): array overlap against the stored snapshot —
    # local, never an external call (locked decisions 4/6). Blank names filter
    # nothing; a name no row carries yields an empty page, never a widened one.
    def tag_filters = Array(@filters[:tags]).map(&:to_s).reject(&:blank?).uniq

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
