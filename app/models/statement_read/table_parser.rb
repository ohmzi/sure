# frozen_string_literal: true

require "date"

class StatementRead
  # The line classifier that turns a statement's `pdftotext -layout` text into
  # transaction rows. (§2b/§2c/§2d of the design, with three amendments.)
  #
  # The rules, keyed to a real statement layout and validated against one:
  #
  #   * The CURRENT SECTION is tracked by the START of a line, never a substring:
  #     `Payments received`/`Returns and other credits` are CREDIT sections;
  #     `Purchases`/`Cash transactions`/`Fees`/`Interest charges` are CHARGE
  #     sections. A specific card (`Purchases - Card #…`) is captured, and
  #     `Purchases (continued)` keeps the card it continues.
  #   * R-W8B7 — a section marker must carry NO amount and must not start with
  #     `Total`. The statement's SUMMARY block prints the same keywords WITH
  #     figures (`Purchases  350.00`, `Interest charges  1.78`); without this a
  #     summary line re-sets the current section.
  #   * A TRANSACTION ROW is a line that BEGINS with a transaction date token.
  #     That one rule excludes every summary line, because none begin with a
  #     date — the payments and interest TABLE rows do, which is the point.
  #     (W8-E widens the token to the numeric forms `09/09`, `09/09/2026`,
  #     `09/09/26`, still anchored at the START of the line.)
  #   * FIELDS split on runs of 2+ spaces, and the amount is the FIRST whole-field
  #     amount, not the last token: `pdftotext -layout` interleaves the
  #     statement's right-hand prose onto the same physical line. (W8-E accepts
  #     ungrouped money, `1234.56`, beside grouped, `1,234.56`.)
  #   * The SIGN comes from the SECTION, never the printed sign — the card prints
  #     charges positive, but the app's rows are negative-for-debits.
  #   * COLLECTION STOPS at a line that STARTS WITH the drill-down heading (a
  #     whole table of per-item detail already counted in Purchases). R-W8B16 —
  #     the stop must not silently drop rows: any date-prefixed line seen after
  #     the stop but BEFORE the drill-down block's own annotation/header is a
  #     truncated real row, recorded in `rejected_lines` and forced untrusted.
  #   * R-W8B8 — a continuation with no previous row is DROPPED, never buffered.
  #   * R-W8B9 — rows are NOT filtered by period membership; the period sets a
  #     yearless date's YEAR only.
  class TableParser
    # The month-name date token ("Sep 08") and the numeric one (W8-E:
    # "09/09" yearless, "09/09/2026", "09/09/26"). The numeric token fixes real
    # month/day ranges, so a rate's "21.99%" (no `/`) or a bare fraction never
    # reads as a date.
    MONTH_NAME = /(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}/
    NUMERIC_DATE = %r{(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])(?:/(?:\d{4}|\d{2}))?}
    # The whole mm/dd[/yy|yyyy] token `iso_date` hand-parses — anchored, so a
    # partial match inside a longer field is not a date.
    NUMERIC_TOKEN = %r{\A(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\z}
    # A transaction row BEGINS with a date, so the anchor is `\A`: prose that
    # merely MENTIONS a date mid-line is never a row.
    MONTH = /\A(?:#{MONTH_NAME}|#{NUMERIC_DATE})\b/
    DATE_PREFIX = /\A(?:#{MONTH_NAME}|#{NUMERIC_DATE})\s+/
    # A whole-field amount, grouped (`1,234.56`) or ungrouped (`1234.56`, W8-E)
    # — never a percentage, a bare integer or a one-decimal figure.
    AMOUNT_FIELD = /\A-?\$?(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\z/
    # A per-row FX detail line ("90.07 USD @ 1.451068613"): a note on the row
    # above, never a row of its own.
    FX_DETAIL = /\d+(?:\.\d+)?\s+[A-Z]{3}\s*@\s*[\d.]+/
    FIELD_SPLIT = / {2,}/
    HEADER_TOKENS = %w[TRANSACTION POSTING DATE DESCRIPTION AMOUNT].freeze
    # Boilerplate that is indented like a wrapped description but is not one.
    BOILERPLATE = /continued on next page|WAY[S]? TO PAY|SEE PAGE|Page \d+ of \d+/i
    # Left edge of the interleaved right-hand prose column. A continuation of a
    # description is indented into the description column (well left of this);
    # the statement's FAQ column starts at or beyond it, so a line here is prose.
    PROSE_COLUMN = 130

    SECTION_MARKERS = {
      "Payments received" => :payments,
      "Returns and other credits" => :returns,
      "Purchases" => :purchases,
      "Cash transactions" => :cash,
      "Fees" => :fees,
      "Interest charges" => :interest
    }.freeze
    CHARGE_SECTIONS = %i[purchases cash fees interest].freeze
    CREDIT_SECTIONS = %i[payments returns].freeze
    # The leading labels of a summary band. None of these is ever a row.
    SUMMARY_PREFIXES = [
      "Total", "Balance from your last statement", "Your New Balance", "Balance Due",
      "Minimum payment due", "Payment due date", "Credit limit", "Available credit",
      "Your payment information", "Statement date", "For the period"
    ].freeze

    # The period/statement-date token, in the bank's human-readable month-name
    # form or the numeric mm/dd/yyyy (or two-digit mm/dd/yy) form (W8-E). The
    # numeric form is read MONTH-first — a bare `Date.parse` would read an
    # ambiguous one day-first. Widening this is REQUIRED alongside the row anchor:
    # a numeric-style statement whose rows we now detect must still be datable, or
    # it is refused as period-unreadable and its yearless rows have no year. The
    # two-digit year is widened to match the row anchor (W8-E), which already
    # accepts `09/09/26`; a statement printed ENTIRELY in two-digit form would
    # otherwise lose the whole deterministic path.
    PERIOD_DATE = /(?:[A-Z][a-z]+ \d{1,2}, \d{4}|\d{1,2}\/\d{1,2}\/(?:\d{4}|\d{2}))/
    PERIOD = /For the period:\s*(#{PERIOD_DATE})\s+to\s+(#{PERIOD_DATE})/
    STATEMENT_DATE = /Statement date:\s*(#{PERIOD_DATE})/
    # The drill-down block's own annotation ("The total of each transaction is
    # included in the Purchases section") — its presence after the stop proves
    # the stop is the real drill-down, not a premature truncation (R-W8B16).
    DRILL_DOWN_ANNOTATION = /included in the\s+Purchases\s+section/i

    # `entries` carry the section/card the reconciliation needs; `rows` is the
    # emitted shape (`route_statement`), which must be exactly the five keys.
    Result = Data.define(:entries, :rows, :missing_date_rows, :rejected_lines, :period_start, :period_end) do
      def period_known? = !(period_start.nil? && period_end.nil?)
      def row_count = rows.size
    end

    def self.call(text) = new(text).call

    def initialize(text)
      @text = text.to_s
    end

    def call
      start_on, end_on = period
      # R-W8B14: without a period there is no year for a yearless `Sep 08`. Do
      # not parse rows into a pile of undated ones — stop with an empty read.
      return empty_result(start_on, end_on) if start_on.nil? && end_on.nil?

      entries, missing, rejected = parse
      Result.new(
        entries: entries, rows: entries.map { |entry| row_shape(entry) },
        missing_date_rows: missing, rejected_lines: rejected,
        period_start: start_on, period_end: end_on
      )
    end

    private
      # The per-line [[text, page], …] walk. Pages come from pdftotext's
      # form-feed between pages. Returns [entries, missing_date_rows,
      # rejected_lines].
      def parse
        entries = []
        missing = []
        rejected = []
        post_stop = []
        section = nil
        card = nil
        in_table = false
        current = nil
        last_page = nil
        stopped = false
        drill_block = false

        lines.each do |raw, page|
          # A page break ends whatever table was open: the next page's boilerplate
          # must not read as a row body.
          if page != last_page
            in_table = false
            current = nil
            last_page = page
          end

          stripped = raw.strip
          next if stripped.empty?

          # R-W8B16: after the drill-down stop, a date-prefixed line is a real
          # row only if it appears before the drill-down block's own marker; such
          # a line is a truncated row and is recorded.
          if stopped
            drill_block = true if drill_down_block_marker?(stripped)
            post_stop << stripped if !drill_block && stripped.match?(MONTH)
            next
          end

          if drill_down_heading?(stripped)
            stopped = true
            next
          end

          if header_band?(stripped)
            in_table = true
            current = nil
            next
          end

          if (marker = section_marker(stripped))
            # A section heading implies a table follows it — with or without a
            # repeated column header (the second card's rows carry none).
            in_table = true
            if marker[:section] == :purchases
              section = :purchases
              card = marker[:card] if marker[:card]
            else
              section = marker[:section]
              card = nil
            end
            current = nil
            next
          end

          if total_band?(stripped)
            in_table = false
            current = nil
            next
          end

          next unless in_table

          if stripped.match?(MONTH)
            entry = parse_row(stripped, section, card, page)
            if entry
              entries << entry
              current = entry
            else
              # A date-led line we could not build a row from — its money is
              # missing. Surfaced, never a silent drop.
              rejected << stripped
            end
            next
          end

          if current && stripped.match?(FX_DETAIL)
            current["notes"] = [ current["notes"], stripped ].compact.join(" ")
            next
          end

          if continuation?(raw, stripped)
            current["name"] = "#{current['name']} #{stripped}".strip if current
            # R-W8B8: a continuation with no previous row is dropped, never
            # buffered into the next row.
            next
          end

          # A dateless line that still carries a whole-field amount: a row whose
          # date the layer lost. Blocks publish; never merged, never dropped.
          if fields(stripped).any? { |field| field.match?(AMOUNT_FIELD) }
            missing << stripped
          end
          # Anything else inside a table is page furniture / right-hand prose.
        end

        rejected.concat(post_stop)
        [ entries, missing, rejected ]
      end

      # A transaction row from a date-led line, or nil when it cannot be built.
      def parse_row(stripped, section, card, page)
        parts = fields(stripped)
        index = parts.index { |field| field.match?(AMOUNT_FIELD) }
        return nil if index.nil? || index.zero?

        date = iso_date(parts.first)
        return nil if date.nil?

        value = BigDecimal(parts[index].delete("$").delete(","))
        value = -value.abs if CHARGE_SECTIONS.include?(section)
        value = value.abs if CREDIT_SECTIONS.include?(section)

        {
          "date" => date, "name" => row_name(parts, index), "amount" => format("%.2f", value),
          "notes" => nil, "source_page" => page, "section" => section, "card" => card
        }
      rescue ArgumentError
        nil
      end

      # The description fields before the amount, single-spaced, with a leading
      # posting date stripped: in the credits table the posting date is glued to
      # the description with a SINGLE space ("Sep 12   Sep 14 Amazon.ca …"), so
      # the 2+-space split leaves it inside the name field.
      def row_name(parts, amount_index)
        parts[1...amount_index].join(" ").sub(DATE_PREFIX, "").strip
      end

      # The emitted row shape — exactly what `route_statement` consumes.
      def row_shape(entry)
        entry.slice("date", "name", "amount", "notes", "source_page")
      end

      def fields(stripped) = stripped.split(FIELD_SPLIT)

      def header_band?(stripped)
        return false if stripped.match?(MONTH)

        tokens = stripped.upcase.scan(/[A-Z]+/)
        (HEADER_TOKENS & tokens).size >= 2
      end

      # The section a line starts, with its card when it names one — matched on
      # the START of the line (R-W8B7: no amount, not a `Total …`), so page-1
      # prose and the summary figures cannot flip the section.
      def section_marker(stripped)
        return nil if stripped.start_with?("Total")
        return nil if fields(stripped).any? { |field| field.match?(AMOUNT_FIELD) }

        return { section: :purchases, card: card_from(stripped) } if stripped.start_with?("Purchases")

        SECTION_MARKERS.each do |prefix, section|
          return { section: section } if stripped.start_with?(prefix)
        end
        nil
      end

      # Only the header's own column: the text layer can carry the side panel's
      # prose on the same line (the live August/September statements), and
      # reading to the end of the line took the panel's digits as the card.
      def card_from(stripped)
        match = fields(stripped).first.to_s.match(/Card #(.+)\z/)
        return nil unless match

        digits = match[1].gsub(/\D/, "")
        digits.length >= 4 ? digits[-4..] : nil
      end

      def total_band?(stripped) = SUMMARY_PREFIXES.any? { |prefix| stripped.start_with?(prefix) }

      def drill_down_heading?(stripped)
        stripped.start_with?("Details of your") && stripped.include?("store purchases")
      end

      # The drill-down block's own marker: its annotation line, or the
      # QUANTITY/DETAILS header shape of the per-item table.
      def drill_down_block_marker?(stripped)
        return true if stripped.match?(DRILL_DOWN_ANNOTATION)

        tokens = stripped.upcase.scan(/[A-Z]+/)
        tokens.include?("QUANTITY") && tokens.include?("DETAILS")
      end

      # A wrapped description (indented into the description column, no date, no
      # amount, not the right-hand prose, not boilerplate).
      def continuation?(raw, stripped)
        lead = raw[/\A */].length
        return false if lead < 4 || lead >= PROSE_COLUMN
        return false if stripped.match?(MONTH) || stripped.match?(FX_DETAIL) || stripped.match?(BOILERPLATE)

        fields(stripped).none? { |field| field.match?(AMOUNT_FIELD) }
      end

      # The row's ISO date. The month-name path is unchanged. A numeric token
      # (W8-E) is parsed by hand — `Date._parse` would misread "09/09/26" as
      # mday 26 / year 2009 — with its year taken from the token, or from the
      # statement's period when the token is yearless. Mirrors
      # `DocumentUnderstandingJob#reanchor_row_date`; that method is a private
      # instance method and cannot be shared with a PORO, so its semantics are
      # re-implemented here.
      def iso_date(token)
        if (match = token.match(NUMERIC_TOKEN))
          return numeric_iso_date(match[1].to_i, match[2].to_i, match[3])
        end

        parts = Date._parse(token)
        month = parts[:mon]
        day = parts[:mday]
        return nil if month.nil? || day.nil?

        year = period_year_for(month, day)
        year && Date.new(year, month, day).iso8601
      rescue Date::Error
        nil
      end

      def numeric_iso_date(month, day, year_text)
        return nil unless (1..12).cover?(month) && (1..31).cover?(day)

        year = numeric_year(year_text, month, day)
        return nil unless year && Date.valid_date?(year, month, day)

        Date.new(year, month, day).iso8601
      rescue Date::Error
        nil
      end

      # An explicit four-digit year is honoured as printed; a two-digit year
      # carries no century, so take the one that lands NEAREST the statement's
      # period — a 2026 statement reads "26" as 2026, not 1926; a yearless token
      # takes the period's year, exactly as the month-name form does.
      def numeric_year(year_text, month, day)
        return period_year_for(month, day) if year_text.nil?
        return year_text.to_i if year_text.length == 4

        anchor = period_anchor
        return nil if anchor.nil?

        century_for(year_text.to_i, anchor.year)
      end

      # The century a two-digit year belongs to: the candidate year that lands
      # nearest the anchor. Shared by the row dates (anchored to the period) and
      # the period's own two-digit year (anchored to today — see
      # `parse_period_date`).
      def century_for(two_digits, anchor_year)
        [ 1900, 2000, 2100 ].map { |century| century + two_digits }
                            .min_by { |candidate| (candidate - anchor_year).abs }
      end

      # The nearest year in the statement's own period (the only honest anchor
      # for a yearless date).
      def period_year_for(month, day)
        years = period_years
        return nil if years.empty?

        anchor = period_anchor
        years.min_by { |candidate| (Date.new(candidate, month, day) - anchor).abs }
      end

      def period
        return @period if defined?(@period)

        @period = begin
          start_on = end_on = nil
          if (match = @text.match(PERIOD))
            start_on = parse_period_date(match[1])
            end_on = parse_period_date(match[2])
          elsif (match = @text.match(STATEMENT_DATE))
            end_on = parse_period_date(match[1])
          end
          [ start_on, end_on ]
        rescue Date::Error
          [ nil, nil ]
        end
      end

      # The period token, month-name ("September 9, 2026") or numeric
      # ("09/09/2026" or the two-digit "09/09/26"). The numeric form is parsed by
      # HAND (mm/dd/yyyy): an ambiguous `Date.parse("10/08/2026")` reads it as 8
      # October (dd/mm), the opposite of the row dates and of the statement's own
      # month/day order. A two-digit year is resolved to the century nearest TODAY
      # — the same nearest-century rule `numeric_year` applies to row dates, but
      # the period is what anchors THEM, so with no four-digit year printed
      # anywhere to anchor the period itself (a statement printed entirely in
      # two-digit form) today is the only honest reference.
      def parse_period_date(token)
        if (match = token.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})\z}))
          year = match[3].length == 4 ? match[3].to_i : century_for(match[3].to_i, Date.current.year)
          Date.new(year, match[1].to_i, match[2].to_i)
        else
          Date.parse(token)
        end
      end

      def period_years = [ period[0]&.year, period[1]&.year ].compact.uniq
      def period_anchor = period[1] || period[0]

      def empty_result(start_on, end_on)
        Result.new(entries: [], rows: [], missing_date_rows: [], rejected_lines: [],
                   period_start: start_on, period_end: end_on)
      end

      def lines
        @lines ||= @text.split("\f").each_with_index.flat_map do |page_text, index|
          page_text.each_line.map { |line| [ line.chomp, index + 1 ] }
        end
      end
  end
end
