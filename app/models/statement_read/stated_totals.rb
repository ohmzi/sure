# frozen_string_literal: true

class StatementRead
  # The statement's OWN printed figures, parsed from the full text (§3). Works on
  # both a `pdftotext -layout` layer and the app's OCR text, so the gate can run
  # on either front-end. Every figure is nullable — many banks print none — and a
  # nil figure is a check the gate must SKIP, never a false pass.
  #
  # Guards: `Total purchases` must not be satisfied by `Total purchases for <card>`
  # (the per-card subtotal line, counted separately), and the summary block's
  # `Purchases`/`Fees`/`Cash transactions` figures are read as stated totals, not
  # as rows.
  class StatedTotals
    # The per-card subtotal: "Total purchases for 5446 12XX XXXX 3111   $4,678.58".
    PER_CARD = /Total purchases for\s+(.+?)\s+(-?\$?\s*[\d,]+\.\d{2})/
    MONEY = /(-?\$?\s*[\d,]+\.\d{2})/

    def self.call(text) = new(text).call

    def initialize(text)
      @text = text.to_s
    end

    def call
      {
        "total_credits" => money(/^\s*Total credits\s+#{MONEY}/),
        "total_charges" => money(/^\s*Total charges\s+#{MONEY}/),
        "purchases" => money(/^\s*Total purchases(?!\s+for)\s+#{MONEY}/),
        "interest" => money(/^\s*Total interest charges\s+#{MONEY}/),
        "payments" => money(/^\s*Total payments received\s+#{MONEY}/),
        "returns_credits" => money(/^\s*Total returns and credits\s+#{MONEY}/),
        "cash" => money(/^\s*Cash transactions\s+#{MONEY}/),
        "fees" => money(/^\s*Fees\s+#{MONEY}/),
        "opening" => money(/^\s*Balance from your last statement\s+#{MONEY}/),
        "new_balance" => money(/^\s*Your New Balance\s+#{MONEY}/),
        "transaction_count" => transaction_count,
        "cards" => per_card_totals
      }
    end

    private
      # The per-card subtotals, keyed by the card's last four digits.
      def per_card_totals
        @text.scan(PER_CARD).each_with_object({}) do |(card, amount), acc|
          digits = card.gsub(/\D/, "")
          acc[digits[-4..]] = money_from(amount) if digits.length >= 4
        end
      end

      # Best-effort, and deliberately conservative: the fixtures print none, so
      # this is nil there and the gate's count sub-check resolves to `skip`.
      def transaction_count
        match = @text.match(/^\s*Total transactions\s+(\d+)\b/i)
        match && match[1].to_i
      end

      def money(regex)
        match = @text.match(regex)
        match && money_from(match[1])
      end

      # A printed money token as a BigDecimal: strip the currency sign and the
      # thousands commas ("-$5,155.00" -> -5155.00).
      def money_from(text)
        BigDecimal(text.to_s.delete("$").delete(",").strip)
      rescue ArgumentError
        nil
      end
  end
end
