class StatementTemplate
  module Bank
    # Chase (JPMorgan Chase) checking/credit statements. Version 1 reads the
    # "MM/DD  description  amount  balance" activity table and infers the year
    # from the statement period line. Only lines that fully match are emitted.
    class Chase < StatementTemplate
      VERSION = 1
      BANK_KEY = "chase"

      HEADER_PATTERNS = [
        /\bJPMorgan Chase\b/i,
        /\bChase\.com\b/i
      ].freeze

      # The statement period names the year; rows carry MM/DD only.
      PERIOD_PATTERN = /
        (?<month>[A-Za-z]{3,9})\s+\d{1,2},\s+(?<year>\d{4})\s+
        through\s+
        [A-Za-z]{3,9}\s+\d{1,2},\s+(?<end_year>\d{4})
      /x.freeze

      ROW_PATTERN = /
        \A
        (?<month>\d{1,2})\/(?<day>\d{1,2})\s+
        (?<description>.+?)\s+
        (?<amount>-?\d{1,3}(?:,\d{3})*\.\d{2})\s+
        (?<balance>-?\d{1,3}(?:,\d{3})*\.\d{2})
        \z
      /x.freeze

      HEADER_SCAN_LINES = 40

      def self.matches?(text)
        head = text.to_s.lines.first(HEADER_SCAN_LINES).join
        HEADER_PATTERNS.any? { |pattern| head.match?(pattern) }
      end

      def rows(text)
        period = period_for(text)
        return [] unless period

        text.to_s.lines.filter_map do |line|
          match = line.strip.match(ROW_PATTERN)
          next unless match

          date = date_for(match, period)
          # (Ruling M2-C5, 2026-10-11 close-out): an impossible MM/DD (for
          # example 02/31) is skipped, never guessed at.
          next unless date

          Row.new(
            date:   date,
            amount: BigDecimal(match[:amount].delete(",")),
            payee:  match[:description].strip,
            memo:   nil
          )
        end
      end

      private

        # (Ruling M2-C5, 2026-10-11 close-out): a period line whose start month
        # does not name a real month (OCR garble) leaves the year inference
        # unusable, so return no period and `rows` emits nothing rather than
        # guessing years (the "never a guess" rule). Before this guard a nil
        # month_number raised ArgumentError from date_for at a year-boundary
        # period line.
        def period_for(text)
          match = text.to_s.match(PERIOD_PATTERN)
          return nil unless match

          start_month = month_number(match[:month])
          return nil unless start_month

          { start_month: start_month, start_year: match[:year].to_i, end_year: match[:end_year].to_i }
        end

        # A statement spanning a year boundary lists December after January;
        # months before the period's start month belong to the end year.
        def date_for(match, period)
          month = match[:month].to_i
          year = if period[:end_year] != period[:start_year] && month < period[:start_month]
            period[:end_year]
          else
            period[:start_year]
          end

          Date.new(year, month, match[:day].to_i)
        rescue Date::Error
          # (Ruling M2-C5, 2026-10-11 close-out): an impossible date is not a
          # transaction line; skip it rather than crash the read.
          nil
        end

        def month_number(name)
          Date::ABBR_MONTHNAMES.index(name[0, 3].capitalize) ||
            Date::MONTHNAMES.index(name.capitalize)
        end
    end
  end
end
