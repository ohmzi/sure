# One merchant pie's worth of data: the selected category's merchant totals,
# keeping the category's dominant direction (spending or income) and turning
# the amounts into chart segments. The money stays in the family currency the
# IncomeStatement already converted to.
class IncomeStatement::MerchantBreakdown
  require "digest/md5"
  require "zlib"

  Row = Data.define(:id, :name, :merchant_id, :merchant_name, :logo_url, :color, :amount, :percentage)
  Result = Data.define(:rows, :total, :currency, :currency_symbol, :direction, :category)

  def initialize(statement, category:, period:)
    @statement = statement
    @category = category
    @period = period
  end

  def call
    totals = @statement.merchant_totals(category: @category, period: @period)
    direction = totals.sum { |total| total.spending.to_d } >= totals.sum { |total| total.income.to_d } ? :spending : :income

    # The SQL groups by the raw merchant/entry name; the normalizer folds the
    # variants (AMZN Mktp, Amazon.ca, Amazon.ae) into one canonical merchant.
    # Use gross spending/income per merchant, so a refund cannot hide a
    # merchant's purchases from the pie.
    groups = totals.group_by { |total| Merchant::NameNormalizer.canonical_name(total.name) }
    included = groups.filter_map do |canonical_name, group|
      amount = group.sum { |total| direction == :spending ? total.spending.to_d : total.income.to_d }
      next if amount.zero?

      { name: canonical_name, amount: amount, rows: group }
    end
    amount_total = included.sum { |group| group[:amount] }
    return empty_result if amount_total.zero?

    merchants = canonical_merchants
    rows = included.map do |group|
      build_row(group, merchants[group[:name]], amount_total)
    end.sort_by { |row| -row.amount }

    Result.new(
      rows: rows,
      total: amount_total,
      currency: @statement.family.currency,
      currency_symbol: Money::Currency.new(@statement.family.currency).symbol,
      direction: direction,
      category: @category
    )
  end

  private
    def empty_result
      Result.new(
        rows: [], total: 0.to_d, currency: @statement.family.currency,
        currency_symbol: Money::Currency.new(@statement.family.currency).symbol,
        direction: :spending, category: @category
      )
    end

    # FamilyMerchant wins over a provider merchant with the same name, so a
    # canonicalized group uses the curated logo/colour.
    def canonical_merchants
      @statement.family.merchants.to_a
                 .sort_by { |merchant| merchant.is_a?(FamilyMerchant) ? 1 : 0 }
                 .index_by(&:name)
    end

    def build_row(group, merchant, amount_total)
      amount = group[:amount]
      source = group[:rows].find { |row| row.logo_url.present? } || group[:rows].first

      Row.new(
        id: segment_id(group[:name]),
        name: group[:name],
        merchant_id: merchant&.id,
        merchant_name: group[:name],
        logo_url: merchant&.logo_url.presence || source&.logo_url,
        color: merchant&.color.presence || source&.color.presence || color_for(group[:name]),
        amount: amount,
        percentage: (amount / amount_total * 100).round(1)
      )
    end

    # A stable, DOM-safe id: the donut controller looks up `#segment_<id>`.
    def segment_id(name)
      "merchant-#{Digest::MD5.hexdigest(name)[0, 12]}"
    end

    def color_for(name)
      FamilyMerchant::COLORS[Zlib.crc32(name) % FamilyMerchant::COLORS.size]
    end
end
