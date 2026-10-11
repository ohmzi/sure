# frozen_string_literal: true

# Deterministic OCR-text parser for receipt/bill drafts. No LLM and no
# probabilistic step (M7 decisions: never a guess). The total comes ONLY from a
# labelled total line — there is deliberately no "largest money token" fallback,
# because this parser feeds a money writer (unlike ReceiptMatcher::Extractor,
# whose best-effort amount only ranks candidates; see the cross-milestone note
# in the plan's self-review). Date/payee heuristics follow M3's extractor so the
# two never disagree about the same receipt.
class ReceiptImport::Extractor
  # A total label followed (within a short span) by a money token. Same pattern
  # family as ReceiptMatcher::Extractor::TOTAL_LABEL (M3) — "amount due",
  # "balance due", "grand total", "total".
  TOTAL_LABEL = /\b(?:grand\s+total|amount\s+due|balance\s+due|total)\b[^\d$\n]{0,20}\$?\s*(\d[\d,]*\.\d{2})/i
  MONEY_TOKEN = /\$?\s*(\d[\d,]*\.\d{2})/
  ISO_DATE = /\b(\d{4})-(\d{2})-(\d{2})\b/
  SLASH_DATE = %r{\b(\d{1,2})[/. -](\d{1,2})[/. -](\d{2,4})\b}
  # Lines that carry money but are never items (labels, tender lines, taxes).
  NON_ITEM_LABEL = /\b(?:sub\s*total|subtotal|tax|vat|gst|change|cash|card|visa|mastercard|amex|debit|credit|balance|tender|paid)\b/i
  # "<description ...>  <money>" — the description must hold letters, the money
  # must end the line (an optional trailing card/alpha marker is tolerated).
  LINE_ITEM = /\A(?<description>\S.{1,58}?)\s{1,}\$?\s*(?<amount>\d[\d,]*\.\d{2})(?:\s*[A-Z*]{1,3})?\z/
  MAX_LINE_ITEMS = 50

  def self.call(text)
    new(text.to_s).call
  end

  def initialize(text)
    @text = text
  end

  def call
    ReceiptImport::Extraction.new(
      total: extract_total,
      date: extract_date,
      payee: extract_payee,
      line_items: extract_line_items
    )
  end

  private
    def extract_total
      match = @text.match(TOTAL_LABEL)
      match && to_amount(match[1])
    end

    def to_amount(token)
      BigDecimal(token.delete(","))
    rescue ArgumentError
      nil
    end

    def extract_line_items
      @text.each_line.filter_map do |line|
        match = line.strip.match(LINE_ITEM) or next
        next if line.match?(TOTAL_LABEL) || line.match?(NON_ITEM_LABEL)
        next unless match[:description].match?(/[A-Za-z]/)

        amount = to_amount(match[:amount]) or next
        next unless amount.positive?

        ReceiptImport::Extraction::LineItem.new(description: match[:description].strip, amount: amount)
      end.first(MAX_LINE_ITEMS)
    end

    def extract_date
      if (match = @text.match(ISO_DATE))
        build_date(match[1].to_i, match[2].to_i, match[3].to_i, iso: true)
      elsif (match = @text.match(SLASH_DATE))
        build_date(match[1].to_i, match[2].to_i, match[3].to_i, iso: false)
      end
    end

    # a/b/c is month/day/year when a <= 12 (US receipts), else day/month/year.
    def build_date(a, b, c, iso:)
      return safe_date(a, b, c) if iso

      year = c < 100 ? 2000 + c : c
      a <= 12 ? safe_date(year, a, b) : safe_date(year, b, a)
    end

    def safe_date(year, month, day)
      Date.new(year, month, day)
    rescue Date::Error
      nil
    end

    # The first line that is not empty, not numeric-only, not a money token and
    # not a total label — the merchant header on a typical receipt.
    def extract_payee
      @text.each_line.map(&:strip).find do |line|
        next false if line.empty? || line.length > 60
        next false if line.match?(MONEY_TOKEN)
        next false if line.match?(/\A[\d\s\/.\-:]+\z/)
        next false if line.match?(TOTAL_LABEL) || line.match?(NON_ITEM_LABEL)
        true
      end
    end
end
