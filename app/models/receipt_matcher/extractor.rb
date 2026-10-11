# Deterministic OCR-text parser. No LLM and no probabilistic step: a fixed,
# ordered set of patterns, and nil when no amount can be found, so the matcher
# degrades to :no_match rather than guessing an amount (D8).
class ReceiptMatcher::Extractor
  # A total label followed (within a short span) by a money token.
  TOTAL_LABEL = /\b(?:grand\s+total|amount\s+due|balance\s+due|total)\b[^\d$\n]{0,20}\$?\s*(\d[\d,]*\.\d{2})/i
  MONEY_TOKEN = /\$?\s*(\d[\d,]*\.\d{2})/
  ISO_DATE = /\b(\d{4})-(\d{2})-(\d{2})\b/
  SLASH_DATE = %r{\b(\d{1,2})[/. -](\d{1,2})[/. -](\d{2,4})\b}

  def self.call(text)
    new(text).call
  end

  def initialize(text)
    @text = text.to_s
  end

  def call
    amount = extract_amount
    return nil if amount.nil?

    ReceiptMatcher::Extraction.new(amount: amount, date: extract_date, payee: extract_payee)
  end

  private
    def extract_amount
      if (match = @text.match(TOTAL_LABEL))
        to_amount(match[1])
      else
        # Documented last resort: the largest money token on the page.
        @text.scan(MONEY_TOKEN).flatten.map { |token| to_amount(token) }.max
      end
    end

    def to_amount(token)
      BigDecimal(token.delete(","))
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
      lines = @text.each_line.map(&:strip)
      lines.find do |line|
        next false if line.empty?
        next false if line.length > 60
        next false if line.match?(MONEY_TOKEN)
        next false if line.match?(/\A[\d\s\/.\-:]+\z/)
        next false if line.match?(TOTAL_LABEL)
        true
      end
    end
end
