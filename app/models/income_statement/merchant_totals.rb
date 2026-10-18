# Merchant-level totals for one category (and its subcategories) over a
# period. It reuses the dashboard's transaction scoping and currency
# conversion so a merchant slice adds up to the same money the category
# totals report.
class IncomeStatement::MerchantTotals
  include IncomeStatement::ScopedTransactionsQuery

  Row = Data.define(:merchant_id, :name, :logo_url, :color, :spending, :income, :total, :transactions_count)

  def initialize(family, transactions_scope:, date_range:, category_ids:, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @category_ids = Array(category_ids).compact
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    return [] if @category_ids.empty? || @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      Row.new(
        merchant_id: row["merchant_id"],
        name: row["name"],
        logo_url: row["logo_url"],
        color: row["color"],
        spending: row["spending"],
        income: row["income"],
        total: row["total"],
        transactions_count: row["transactions_count"]
      )
    end
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ sql, sql_params ])
    end

    def sql
      converted = converted_amount_sql("at")

      <<~SQL
        SELECT
          m.id::text AS merchant_id,
          COALESCE(m.name, ae.name) AS name,
          m.logo_url AS logo_url,
          m.color AS color,
          SUM(CASE WHEN (#{converted}) > 0 THEN (#{converted}) ELSE 0 END) AS spending,
          SUM(CASE WHEN (#{converted}) < 0 THEN -(#{converted}) ELSE 0 END) AS income,
          SUM(#{converted}) AS total,
          COUNT(ae.id) AS transactions_count
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        LEFT JOIN merchants m ON m.id = at.merchant_id
        #{exchange_rates_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          #{investment_activity_label_sql("at")}
          AND at.category_id IN (:category_ids)
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY m.id, COALESCE(m.name, ae.name), m.logo_url, m.color
        ORDER BY ABS(SUM(#{converted})) DESC, name ASC
      SQL
    end

    def sql_params
      base_sql_params(
        start_date: @date_range.begin,
        end_date: @date_range.end,
        category_ids: @category_ids
      ).tap do |params|
        params[:included_account_ids] = @included_account_ids if @included_account_ids
      end
    end
end
