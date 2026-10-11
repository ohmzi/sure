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
    scope = @family.account_statements
      .where(account_id: nil)
      .or(@family.account_statements.where(account_id: @user.accessible_accounts.select(:id)))
      .includes(:account, :suggested_account, :archived_document_link)
    scope = scope.where(extraction_state: extraction_filters) if extraction_filters.any?
    scope = scope.where(review_status: review_filters) if review_filters.any?
    scope = scope.merge(AccountStatement.search(@filters[:search])) if @filters[:search].present?
    scope = scope.where("#{DOCUMENT_DATE_SQL} >= ?", date_from.iso8601) if date_from
    scope = scope.where("#{DOCUMENT_DATE_SQL} <= ?", date_to.iso8601) if date_to
    scope.order(order_clause)
  end

  private
    def extraction_filters = Array(@filters[:extraction]) & EXTRACTION_FILTERS
    def review_filters = Array(@filters[:review]) & REVIEW_FILTERS

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
      when "document_date" then Arel.sql("#{DOCUMENT_DATE_SQL} DESC, account_statements.created_at DESC")
      when "name" then Arel.sql("LOWER(account_statements.filename) ASC, account_statements.created_at DESC")
      else { created_at: :desc }
      end
    end
end
