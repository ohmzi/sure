# frozen_string_literal: true

# Reads a receipt or bill from its own text (the OCR text, or a PDF's text
# layer) before any model is asked — the owner's rule (2026-10-16): the reader
# first, the model only for what the text cannot give.
#
# It never guesses: an ambiguous numeric date ("03/04/2026") is left for the
# model, and the read is `checked` only when the document's own arithmetic
# holds — items = subtotal, and subtotal + taxes + tip = total. A total with
# nothing to add up is read but not proven.
#
# Deliberately stricter than ReceiptMatcher::Extractor, which serves inbox
# suggestions and may fall back to the largest amount or guess a date order.
class ReceiptRead
  MONEY_AT_END = /(-?)\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})\s*\z/
  SUBTOTAL = /\bsub\s*-?\s*total\b/i
  TAX = /\b(HST|GST|PST|QST|TVQ|TPS|VAT|TAX)\b/i
  TIP = /\b(?:tip|gratuity)\b/i
  TOTAL = /\b(?:grand\s+total|total|amount\s+due|balance\s+due)\b/i
  NOT_A_TOTAL = /savings|items|discount|points/i
  PAYMENT = /\b(?:visa|master\s?card|amex|debit|credit|cash|change|tendered|interac|card)\b/i
  BILL = /\b(?:amount\s+due|due\s+date|billing\s+period|invoice|account\s+number)\b/i
  MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
  NAMED_DATE = /\b(#{MONTHS.join('|')})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b/i
  ISO_DATE = /\b(\d{4})-(\d{2})-(\d{2})\b/
  SLASH_DATE = %r{\b(\d{1,2})/(\d{1,2})/(\d{4})\b}
  NOT_THE_DATE = /\bdue\b|\bperiod\b/i

  Result = Data.define(:total, :subtotal, :taxes, :tip, :date, :merchant, :items, :checked, :document_class, :missing) do
    def complete? = total.present? && date.present?
  end

  def self.call(text) = new(text).call

  def initialize(text)
    @lines = text.to_s.each_line.map(&:rstrip).reject(&:blank?)
  end

  def call
    parse_amount_lines
    taxes = @taxes
    tip = @tip
    checked = proven?(taxes, tip)
    date = read_date
    merchant = read_merchant
    Result.new(
      total: @total, subtotal: @subtotal, taxes: taxes, tip: tip, date: date, merchant: merchant,
      items: @items, checked: checked, document_class: @lines.join("\n").match?(BILL) ? "bill" : "receipt",
      missing: { "total" => @total, "date" => date, "merchant" => merchant }.select { |_, value| value.nil? }.keys
    )
  end

  private
    # Each line ending in an amount is a subtotal, a tax, a tip, a total, a
    # payment (ignored), or — before the summary starts — an item.
    def parse_amount_lines
      @items = []
      @taxes = {}
      @tip = nil
      @subtotal = nil
      @total = nil
      summary_started = false

      @lines.each do |line|
        match = line.match(MONEY_AT_END)
        next unless match

        amount = BigDecimal(match[2].delete(","))
        amount = -amount if match[1] == "-"
        label = line[0...match.begin(0)].strip

        if label.match?(SUBTOTAL)
          @subtotal = amount
          summary_started = true
        elsif label.match?(TOTAL) && !label.match?(NOT_A_TOTAL)
          @total = amount
          summary_started = true
        elsif label.match?(TIP)
          @tip = amount
          summary_started = true
        elsif (tax = label[TAX, 1])
          @taxes[tax.upcase] = (@taxes[tax.upcase] || BigDecimal(0)) + amount
          summary_started = true
        elsif label.match?(PAYMENT) || summary_started || label.blank?
          next
        else
          @items << { "description" => label.squish, "amount" => amount }
        end
      end
    end

    def proven?(taxes, tip)
      return false if @total.nil?

      extras = taxes.values.sum(BigDecimal(0)) + (tip || 0)
      items_sum = @items.sum(BigDecimal(0)) { |item| item["amount"] }
      if @subtotal
        (@items.empty? || items_sum == @subtotal) && @subtotal + extras == @total && (@items.any? || extras.positive?)
      elsif @items.any?
        items_sum + extras == @total
      else
        false
      end
    end

    # The document's own date: ISO, then a month-name date, then a numeric date
    # whose order the numbers themselves settle. A due date or a billing period
    # is not the document's date.
    def read_date
      @lines.each do |line|
        next if line.match?(NOT_THE_DATE)

        date = iso_date(line) || named_date(line) || numeric_date(line)
        return date if date
      end
      nil
    end

    def iso_date(line)
      match = line.match(ISO_DATE) or return nil
      safe_date(match[1].to_i, match[2].to_i, match[3].to_i)
    end

    def named_date(line)
      match = line.match(NAMED_DATE) or return nil
      safe_date(match[3].to_i, MONTHS.index(match[1].downcase.first(3)) + 1, match[2].to_i)
    end

    # "09/28/2026" can only be month/day; "28/09/2026" only day/month;
    # "03/04/2026" is either, so it is left for the model.
    def numeric_date(line)
      match = line.match(SLASH_DATE) or return nil
      first, second, year = match[1].to_i, match[2].to_i, match[3].to_i
      if first > 12 then safe_date(year, second, first)
      elsif second > 12 then safe_date(year, first, second)
      end
    end

    def safe_date(year, month, day)
      Date.new(year, month, day)
    rescue Date::Error, ArgumentError
      nil
    end

    # The first line that reads like a name: letters, no amount, not a date,
    # an address, a phone number or a document heading. A best guess the model
    # may overrule (it can read a logo).
    def read_merchant
      @lines.first(5).find do |line|
        text = line.strip
        text.length.between?(3, 60) && text.count("A-Za-z") >= 3 && !text.match?(MONEY_AT_END) &&
          !text.match?(/\A\d/) && !text.match?(/\(\d{3}\)|\d{3}-\d{4}/) && !text.match?(ISO_DATE) &&
          !text.match?(NAMED_DATE) && !text.match?(/\b(?:date|server|table|account|statement)\b/i)
      end&.strip
    end
end
