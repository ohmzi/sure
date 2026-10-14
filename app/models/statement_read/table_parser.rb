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
  #   * FIELDS split on runs of 2+ spaces, and the amount is the FIRST whole-field
  #     amount, not the last token: `pdftotext -layout` interleaves the
  #     statement's right-hand prose onto the same physical line.
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
    MONTH = /\A(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\b/
    DATE_PREFIX = /\A(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+/
    AMOUNT_FIELD = /\A-?\$?\d{1,3}(?:,\d{3})*\.\d{2}\z/
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

    PERIOD = /For the period:\s*([A-Z][a-z]+ \d{1,2}, \d{4})\s+to\s+([A-Z][a-z]+ \d{1,2}, \d{4})/
    STATEMENT_DATE = /Statement date:\s*([A-Z][a-z]+ \d{1,2}, \d{4})/
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

      def card_from(stripped)
        match = stripped.match(/Card #(.+)\z/)
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

      # The row's ISO date, its year taken from the statement's own period (the
      # only honest anchor for a yearless "Sep 08"). Mirrors
      # `DocumentUnderstandingJob#reanchor_row_date`; that method is a private
      # instance method and cannot be shared with a PORO, so its semantics are
      # re-implemented here.
      def iso_date(token)
        parts = Date._parse(token)
        month = parts[:mon]
        day = parts[:mday]
        return nil if month.nil? || day.nil?

        years = period_years
        return nil if years.empty?

        anchor = period_anchor
        year = years.min_by { |candidate| (Date.new(candidate, month, day) - anchor).abs }
        Date.new(year, month, day).iso8601
      rescue Date::Error
        nil
      end

      def period
        return @period if defined?(@period)

        @period = begin
          start_on = end_on = nil
          if (match = @text.match(PERIOD))
            start_on = Date.parse(match[1])
            end_on = Date.parse(match[2])
          elsif (match = @text.match(STATEMENT_DATE))
            end_on = Date.parse(match[1])
          end
          [ start_on, end_on ]
        rescue Date::Error
          [ nil, nil ]
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
