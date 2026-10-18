# One merchant pie's worth of data: the selected category's merchant totals,
# keeping the category's dominant direction (spending or income) and turning
# the amounts into chart segments. The money stays in the family currency the
# IncomeStatement already converted to.
class IncomeStatement::MerchantBreakdown
  require "digest/md5"
  require "zlib"

  # Refund merchants keep a neutral slice colour so the pie never reads a
  # credit as spending.
  REFUND_COLOR = "#737373".freeze

  Row = Data.define(:id, :name, :merchant_id, :merchant_name, :logo_url, :color, :amount, :percentage, :negative)
  Result = Data.define(:rows, :refunds, :total, :net_total, :currency, :currency_symbol, :direction, :category)

  def initialize(statement, category:, period:)
    @statement = statement
    @category = category
    @period = period
  end

  def call
    totals = @statement.merchant_totals(category: @category, period: @period)

    # The SQL groups by the raw merchant/entry name; the normalizer folds the
    # variants (AMZN Mktp, Amazon.ca, Amazon.ae) into one canonical merchant.
    # Each merchant's value is its net after refunds.
    groups = totals.group_by { |total| Merchant::NameNormalizer.canonical_name(total.name) }
    nets = groups.filter_map do |canonical_name, group|
      net = group.sum { |total| total.total.to_d }
      next if net.zero?

      { name: canonical_name, net: net, rows: group }
    end
    return empty_result if nets.empty?

    positive = nets.select { |group| group[:net].positive? }.sum { |group| group[:net] }
    negative = nets.select { |group| group[:net].negative? }.sum { |group| group[:net].abs }
    direction = positive >= negative ? :spending : :income
    sided, refunds = if direction == :spending
      [ nets.select { |group| group[:net].positive? }, nets.select { |group| group[:net].negative? } ]
    else
      [ nets.select { |group| group[:net].negative? }, nets.select { |group| group[:net].positive? } ]
    end

    pie_total = sided.sum { |group| group[:net].abs }
    refund_total = refunds.sum { |group| group[:net].abs }
    net_total = pie_total - refund_total
    activity_total = pie_total + refund_total

    merchants = canonical_merchants
    rows = sided.map do |group|
      build_row(group, merchants[group[:name]], activity_total, negative: false)
    end.sort_by { |row| -row.amount }
    refund_rows = refunds.map do |group|
      build_row(group, merchants[group[:name]], activity_total, negative: true)
    end.sort_by { |row| -row.amount }

    Result.new(
      rows: rows,
      refunds: refund_rows,
      total: pie_total,
      net_total: net_total,
      currency: @statement.family.currency,
      currency_symbol: Money::Currency.new(@statement.family.currency).symbol,
      direction: direction,
      category: @category
    )
  end

  private
    def empty_result
      Result.new(
        rows: [], refunds: [], total: 0.to_d, net_total: 0.to_d, currency: @statement.family.currency,
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

    def build_row(group, merchant, denominator, negative:)
      amount = group[:net].abs
      source = group[:rows].find { |row| row.logo_url.present? } || group[:rows].first

      Row.new(
        id: segment_id(group[:name]),
        name: group[:name],
        merchant_id: merchant&.id,
        merchant_name: group[:name],
        logo_url: merchant&.logo_url.presence || source&.logo_url,
        color: negative ? REFUND_COLOR : (merchant&.color.presence || source&.color.presence || color_for(group[:name])),
        amount: amount,
        percentage: denominator.zero? ? 0 : (amount / denominator * 100).round(1),
        negative: negative
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
