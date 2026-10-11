# frozen_string_literal: true

# The statements page's scope builder (M8 locked decision 2). Starts from the
# vault's per-user visible scope — the same rule the pre-M8 index enforced —
# so the rewrite cannot leak another user's private-account statements.
class AccountStatement::Search
  EXTRACTION_FILTERS = AccountStatement.extraction_states.keys.freeze
  REVIEW_FILTERS = AccountStatement.review_statuses.keys.freeze

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
    scope.order(created_at: :desc)
  end

  private
    def extraction_filters = Array(@filters[:extraction]) & EXTRACTION_FILTERS
    def review_filters = Array(@filters[:review]) & REVIEW_FILTERS
end
