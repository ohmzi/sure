# frozen_string_literal: true

# The statements page's scope builder (M8 locked decision 2). Starts from the
# vault's per-user visible scope — the same rule the pre-M8 index enforced —
# so the rewrite cannot leak another user's private-account statements.
class AccountStatement::Search
  EXTRACTION_FILTERS = AccountStatement.extraction_states.keys.freeze
  REVIEW_FILTERS = AccountStatement.review_statuses.keys.freeze
  # One sort vocabulary across both pages (M8 locked decision 5): aliased, not
  # copied, so the two select boxes can never drift.
  SORTS = DocumentLink::Search::SORTS

  # The statements' derived document date (M8 locked decision 5): the period
  # end when known, else the upload date. ISO text, so the lexicographic
  # comparison is chronological. The sort/range authority; the row's displayed
  # date mirrors it in Ruby.
  DOCUMENT_DATE_SQL = <<~SQL.squish.freeze
    COALESCE(
      to_char(account_statements.period_end_on, 'YYYY-MM-DD'),
      to_char(account_statements.created_at, 'YYYY-MM-DD')
    )
  SQL

  def initialize(user:, family:, filters: {})
    @user = user
    @family = family
    @filters = filters.symbolize_keys
  end

  def relation
    @scope = @family.account_statements
      .visible_to(@user)
      .excluding_tombstones
      .includes(:account, :suggested_account, :archived_document_link)
    @scope = @scope.where(extraction_state: extraction_filters) if extraction_filters.any?
    @scope = @scope.where(review_status: review_filters) if review_filters.any?
    @scope = @scope.where(id: attention_scope.select(:id)) if attention_scope
    @scope = @scope.merge(AccountStatement.search(@filters[:search])) if @filters[:search].present?
    @scope = @scope.where("#{DOCUMENT_DATE_SQL} >= ?", date_from.iso8601) if date_from
    @scope = @scope.where("#{DOCUMENT_DATE_SQL} <= ?", date_to.iso8601) if date_to
    @scope = institution_matching(@filters[:merchant])
    @scope = @scope.where(id: tagged_statement_ids) if tag_filters.any?
    @scope.order(order_clause)
  end

  # Every sort ends in the unique id, so equal timestamps or names have one
  # deterministic list order; the viewer's walk can neither skip nor repeat.
  def ordering
    case sort_key
    when "oldest"
      [ { sql: "account_statements.created_at", direction: :asc }, { sql: "account_statements.id", direction: :asc } ]
    when "document_date"
      [
        { sql: DOCUMENT_DATE_SQL, direction: :desc },
        { sql: "account_statements.created_at", direction: :desc },
        { sql: "account_statements.id", direction: :desc }
      ]
    when "name"
      [
        { sql: "LOWER(account_statements.filename)", direction: :asc },
        { sql: "account_statements.created_at", direction: :desc },
        { sql: "account_statements.id", direction: :desc }
      ]
    else
      [ { sql: "account_statements.created_at", direction: :desc }, { sql: "account_statements.id", direction: :desc } ]
    end
  end

  # [previous, next] over this same filtered visible order, without loading
  # the list.
  def neighbours(statement)
    DocumentBrowser::Neighbours.call(relation, statement, ordering)
  end

  private
    attr_reader :scope

    def extraction_filters = Array(@filters[:extraction]) & EXTRACTION_FILTERS
    def review_filters = Array(@filters[:review]) & REVIEW_FILTERS

    # The documents attention strip's actions narrow the vault to exactly the
    # statements it counted: one shared predicate, not a second copy. An
    # unknown value filters nothing.
    def attention_scope
      AccountStatement.attention_scope(@filters[:attention], family: @family)
    end

    # The institution facet (M8 Task 7, locked decision 7): statements have no
    # extracted payee — the "merchant" column is the upload-time institution
    # hint. There is NO amount predicate here: statements carry no extracted
    # total anywhere, so the form renders the honest note instead of dead
    # fields, and a hand-crafted amount param is ignored by construction.
    def institution_matching(term)
      return scope if term.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term.to_s.strip)}%"
      scope.where("institution_name_hint ILIKE :p", p: pattern)
    end

    # The tag facet on statements (M8 Task 6): statements carry no tags of
    # their own, so the filter is a subquery over their archived document
    # links' stored snapshots — local, never an external call (locked decisions 4/6).
    def tag_filters = Array(@filters[:tags]).map(&:to_s).reject(&:blank?).uniq

    def tagged_statement_ids
      DocumentLink.where(source: "statement")
                  .where("tags && ARRAY[?]::text[]", tag_filters)
                  .where.not(account_statement_id: nil)
                  .select(:account_statement_id)
    end

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
      Arel.sql(ordering.map { |key| "#{key.fetch(:sql)} #{key.fetch(:direction).to_s.upcase}" }.join(", "))
    end
end
