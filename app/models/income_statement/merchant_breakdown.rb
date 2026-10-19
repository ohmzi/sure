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
    rows = distinct_colours(rows) { |index| spread_hue(index) }
    refund_rows = distinct_colours(refund_rows, taken: rows.map(&:color)) { |index| refund_shade(index) }

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

    # Every slice its own colour (the owner, 2026-10-19). Biggest first, a row
    # keeps its colour unless a row before it already has that colour; then
    # it takes the next unused palette colour, and once the palette runs out,
    # the next colour from `fallback`.
    def distinct_colours(rows, taken: [])
      used = taken.map(&:downcase)
      palette = FamilyMerchant::COLORS.map(&:downcase)
      fallback_index = 0
      rows.map do |row|
        colour = row.color.to_s.downcase
        if used.include?(colour)
          colour = palette.find { |candidate| !used.include?(candidate) }
          until colour
            candidate = yield(fallback_index)
            fallback_index += 1
            colour = candidate unless used.include?(candidate)
          end
        end
        used << colour
        row.with(color: colour)
      end
    end

    # Evenly spread hues past the palette: the golden angle keeps neighbours apart.
    def spread_hue(index)
      hsl_hex((index * 137.508 + 20) % 360, 0.62, 0.6)
    end

    # Refunds stay grey, told apart by shade.
    def refund_shade(index)
      hsl_hex(0, 0, [ 0.3 + (index * 0.13) % 0.55, 0.85 ].min)
    end

    def hsl_hex(hue, saturation, lightness)
      chroma = (1 - (2 * lightness - 1).abs) * saturation
      x = chroma * (1 - ((hue / 60.0) % 2 - 1).abs)
      m = lightness - chroma / 2
      r, g, b = case hue
      when 0...60 then [ chroma, x, 0 ]
      when 60...120 then [ x, chroma, 0 ]
      when 120...180 then [ 0, chroma, x ]
      when 180...240 then [ 0, x, chroma ]
      when 240...300 then [ x, 0, chroma ]
      else [ chroma, 0, x ]
      end
      format("#%02x%02x%02x", ((r + m) * 255).round, ((g + m) * 255).round, ((b + m) * 255).round)
    end

    # A stable, DOM-safe id: the donut controller looks up `#segment_<id>`.
    def segment_id(name)
      "merchant-#{Digest::MD5.hexdigest(name)[0, 12]}"
    end

    def color_for(name)
      FamilyMerchant::COLORS[Zlib.crc32(name) % FamilyMerchant::COLORS.size]
    end
end
