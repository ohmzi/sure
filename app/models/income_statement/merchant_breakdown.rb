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
    direction = totals.sum { |total| total.total.to_d } >= 0 ? :spending : :income
    sign = direction == :spending ? 1 : -1
    included = totals.select { |total| total.total.to_d * sign > 0 }
    amount_total = included.sum { |total| total.total.to_d.abs }
    return empty_result if amount_total.zero?

    rows = included.map do |total|
      amount = total.total.to_d.abs
      Row.new(
        id: segment_id(total),
        name: total.name,
        merchant_id: total.merchant_id,
        merchant_name: total.name,
        logo_url: total.logo_url,
        color: color_for(total),
        amount: amount,
        percentage: (amount / amount_total * 100).round(1)
      )
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

    # A stable, DOM-safe id: the donut controller looks up `#segment_<id>`.
    def segment_id(total)
      "merchant-#{Digest::MD5.hexdigest(group_key(total))[0, 12]}"
    end

    def group_key(total)
      total.merchant_id.presence || total.name
    end

    def color_for(total)
      total.color.presence || FamilyMerchant::COLORS[Zlib.crc32(group_key(total)) % FamilyMerchant::COLORS.size]
    end
end
