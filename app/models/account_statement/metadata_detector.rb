# frozen_string_literal: true

require "csv"
require "stringio"

class AccountStatement::MetadataDetector
  DATE_PATTERNS = [
    /(?<![a-z0-9])\d{4}[-_\.]\d{1,2}[-_\.]\d{1,2}(?![a-z0-9])/,
    /(?<![a-z0-9])\d{1,2}[-_\.]\d{1,2}[-_\.]\d{4}(?![a-z0-9])/,
    /(?<![a-z0-9])\d{8}(?![a-z0-9])/
  ].freeze
  DATE_TOKEN = Regexp.union(*DATE_PATTERNS)
  # The words (and bare separators) that turn two dates into a period range.
  # "statement 2026-05-09 downloaded 2026-10-18" is two unrelated facts, not a
  # range: only an explicit connector may join the boundaries. A bare gap of
  # whitespace/underscores also connects two dates, but it is weak evidence and
  # only trusted when those are the ONLY two dates in the name (WEAK_RANGE_GAP).
  WEAK_RANGE_GAP = /\A[\s_]+\z/.freeze
  RANGE_GAP = /\A(?:[\s_-]*(?:to|through|until|thru|and|bis|au|al)[\s_-]*|[\s_-]*-[\s_-]*|[\s_-]*[–—][\s_-]*|[\s_]+)\z/i.freeze

  MONTH_PATTERN = /
    (?<![a-z0-9])
    (?:
      (?<year_first>\d{4})[-_\.](?<month_first>0?[1-9]|1[0-2])
      |
      (?<month_name>jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)
      [-_\s\.]+(?<year_second>\d{4})
    )
    (?![a-z0-9])
  /ix.freeze

  LAST4_PATTERN = /(?:^|[^a-z0-9])(?:x{2,}|ending|last\s*4|acct|account|card)[^\d]*(\d{4})(?=\D|$)/i.freeze
  GENERIC_FILENAME_HINTS = [
    "statement",
    "statements",
    "bank statement",
    "bank statements",
    "account statement",
    "account statements",
    "credit card statement",
    "card statement"
  ].freeze
  MAX_CSV_COLUMNS = 100
  MAX_CSV_DATE_SAMPLES = 250
  MAX_CSV_SAMPLE_BYTES = 256
  MAX_PDF_METADATA_PAGES = 2

  # What a filename can say about a period. A two-date filename names the period
  # boundaries exactly; a single date is an anchor whose role is ambiguous, and a
  # month/year names a month. The PeriodCheck treats each with the confidence its
  # shape earns instead of inventing an exact period from a weak token.
  FilenamePeriod = Data.define(:start_on, :end_on, :kind, :anchor_on)

  attr_reader :statement, :content

  def initialize(statement, content:)
    @statement = statement
    @content = content
  end

  def apply
    output = statement.sanitized_parser_output || {}
    metadata_sources = []

    # The document's own text is more reliable than the filename, so it runs
    # first and the filename only fills what it left blank.
    if statement.pdf? && detect_from_pdf(output)
      metadata_sources << "pdf_text"
    end

    if detect_from_filename
      metadata_sources << "filename"
    end

    if statement.csv? && detect_from_csv(output)
      metadata_sources << "csv_dates"
    elsif statement.xlsx?
      output["spreadsheet_detection"] = "filename_only"
    elsif statement.pdf?
      output["pdf_detection"] ||= "filename_only"
    end

    output["metadata_sources"] = metadata_sources
    statement.sanitized_parser_output = output
    statement.parser_confidence ||= if metadata_sources.include?("pdf_text")
      0.85
    elsif metadata_sources.include?("csv_dates")
      0.65
    elsif metadata_sources.any?
      0.45
    else
      0.1
    end
  end

  private

    def detect_from_filename
      basename = File.basename(statement.filename.to_s, ".*")
      return false if basename.blank?

      detected = false

      if (last4 = basename.match(LAST4_PATTERN)&.captures&.first)
        statement.account_last4_hint ||= last4
        detected = true
      end

      if (period = self.class.filename_period(statement.filename,
                                              date_format: statement.family&.date_format))
        statement.period_start_on ||= period.start_on
        statement.period_end_on ||= period.end_on
        detected = true
      end

      hint = basename
        .gsub(LAST4_PATTERN, "")
        .gsub(/\b\d{4}[-_\.]\d{1,2}(?:[-_\.]\d{1,2})?\b/, "")
        .gsub(/\b\d{8}\b/, "")
        .tr("_-", " ")
        .gsub(/\b(?:19|20)\d{2}\b/, "")
        .gsub(/\b(?:0?[1-9]|1[0-2])\b/, "")
        .squish
        .presence

      if (meaningful_hint = meaningful_filename_hint(hint))
        statement.institution_name_hint ||= meaningful_hint
        statement.account_name_hint ||= meaningful_hint
        detected = true
      end

      detected
    end

    def detect_from_pdf(output)
      summary = AccountStatement::TextMetadataParser.parse(pdf_text, currency: statement.currency)
      return false unless summary

      # Keep the printed period beside the stored one. The stored dates may be
      # corrected by the owner (or overwritten by a later read), so a warning
      # that compares the two needs the printed fact recorded independently.
      record_detected_period(output, summary)

      statement.period_start_on ||= summary.period_start_on
      statement.period_end_on ||= summary.period_end_on
      statement.account_last4_hint ||= summary.iban_last4

      # Only keep balances when they are in the statement's currency; a
      # mismatch would make reconciliation compare different currencies.
      balances_kept = summary.currency.present? && (statement.currency.blank? || statement.currency == summary.currency)
      if balances_kept
        statement.currency ||= summary.currency
        statement.opening_balance ||= summary.opening_balance
        statement.closing_balance ||= summary.closing_balance
      end

      output["pdf_detection"] = "text"
      output["pdf"] = {
        "balances_source" => (summary.balances_source if balances_kept),
        "balances_detected" => statement.opening_balance.present? && statement.closing_balance.present?
      }
      true
    end

    # Text of the first pages only: periods and balance summaries sit at the
    # top of a statement. Any reader failure leaves filename detection as the
    # fallback instead of failing the upload.
    def pdf_text
      Pdf::TextExtractor.pages(content, max_pages: MAX_PDF_METADATA_PAGES).join("\n")
    rescue StandardError => e
      Rails.logger.info("AccountStatement::MetadataDetector - PDF text unavailable: #{e.class}")
      ""
    end

    def detect_from_csv(output)
      csv = CSV.new(StringIO.new(content.to_s), headers: true, liberal_parsing: true)
      first_row = csv.shift
      return false if first_row.blank?

      headers = first_row.headers.compact.map(&:to_s)
      return false if headers.size > MAX_CSV_COLUMNS

      date_header = headers.find { |header| csv_sample_text(header).to_s.match?(/date|posted|transaction/i) }
      return false if date_header.blank?

      samples = [ csv_sample_text(first_row[date_header]) ].compact_blank
      csv.each do |row|
        break if samples.size >= MAX_CSV_DATE_SAMPLES

        sample = csv_sample_text(row[date_header])
        samples << sample if sample.present?
      end
      return false if samples.blank?

      date_format = Import.detect_date_format(samples)
      dates = samples.filter_map { |sample| parse_date_with_format(sample, date_format) }.uniq.sort
      return false if dates.blank?

      statement.period_start_on ||= dates.first
      statement.period_end_on ||= dates.last
      output["csv"] = {
        "date_header" => date_header.to_s,
        "date_format" => date_format,
        "rows_sampled" => samples.size
      }
      true
    rescue CSV::MalformedCSVError
      false
    end

    def csv_sample_text(value)
      text = value.to_s
      return nil if text.bytesize > MAX_CSV_SAMPLE_BYTES

      text
    end

    def meaningful_filename_hint(hint)
      return nil if hint.blank?

      normalized = hint.downcase.gsub(/[^a-z0-9]+/, " ").squish
      # Connectors left behind by a date range ("statement 2026-05-09 to
      # 2026-06-08") are not an identity; stripping them keeps the hint from
      # pretending a statement prints a bank/account name it never did.
      without_generic_words = normalized
        .gsub(/\b(?:bank|account|card|credit|debit|statement|statements|to|from|through|until|and)\b/, "")
        .squish

      return nil if GENERIC_FILENAME_HINTS.include?(normalized) || without_generic_words.blank?

      hint
    end

    def parse_date_with_format(value, format)
      date = Date.strptime(value.to_s, format)
      AccountStatement::MetadataDetector.reasonable_date?(date) ? date : nil
    rescue Date::Error, ArgumentError
      nil
    end

    # The printed period is a separate witness from the stored dates. Record it
    # only when the text printed BOTH boundaries; one printed date is not a
    # period and must never become a warning.
    def record_detected_period(output, summary)
      return unless summary.period_start_on.present? && summary.period_end_on.present?

      output["detected_period"] = {
        "start_on" => summary.period_start_on.iso8601,
        "end_on" => summary.period_end_on.iso8601,
        "source" => "pdf_text"
      }
    end

    class << self
      # The date(s) an original filename carries, in the shape each deserves:
      # an explicit two-date range names the period boundaries, a single date is
      # an anchor, and a month/year names a month. Multiple dates with no range
      # connector (a period date plus a download date, say) are unrelated facts
      # and yield nothing rather than an invented range. nil when the filename
      # has no usable date.
      def filename_period(filename, date_format: nil)
        basename = File.basename(filename.to_s, ".*")
        return nil if basename.blank?

        range = explicit_range(basename, date_format)
        return range if range

        dates = date_matches(basename)
                .filter_map { |match| parse_date(match[0], date_format: date_format) }
                .uniq
                .sort
        # Two unrelated dates are not a period. Without an explicit range the
        # only trustworthy shapes are one anchor or a month name.
        return nil if dates.size > 1

        if dates.size == 1
          FilenamePeriod.new(start_on: dates.first.beginning_of_month,
                             end_on: dates.first.end_of_month,
                             kind: :date, anchor_on: dates.first)
        elsif (month_date = parse_month_from_filename(basename))
          FilenamePeriod.new(start_on: month_date.beginning_of_month,
                             end_on: month_date.end_of_month,
                             kind: :month, anchor_on: month_date)
        end
      end

      # Ambiguous numeric dates ("05-06-2026") are read in the family's own
      # order. Without one, only shapings that carry their own order (ISO and
      # YYYYMMDD) are trusted: guessing day-first invented warnings for US
      # statements.
      def parse_date(value, date_format: nil)
        text = value.to_s.tr("_", "-")
        date = if text.match?(/\A\d{8}\z/)
          Date.strptime(text, "%Y%m%d")
        elsif text.match?(/\A\d{4}[-.\/]\d{1,2}[-.\/]\d{1,2}\z/)
          separator = text[4]
          Date.strptime(text, "%Y#{separator}%m#{separator}%d")
        else
          parse_with_format(text, date_format)
        end

        reasonable_date?(date) ? date : nil
      rescue Date::Error, ArgumentError
        nil
      end

      # The family format fixes the field order; the filename fixes the
      # separator. Both must agree, or the token is left unread.
      def parse_with_format(text, date_format)
        return nil if date_format.blank?

        separator = text[/[-.\/]/]
        return nil if separator.nil?

        format = date_format.tr("/", separator).tr("-", separator).tr(".", separator)
        Date.strptime(text, format)
      rescue Date::Error, ArgumentError
        nil
      end

      def explicit_range(basename, date_format)
        matches = date_matches(basename)
        matches.each_cons(2) do |first, second|
          gap = basename[first.end(0)...second.begin(0)].to_s
          next unless gap.match?(RANGE_GAP)
          # A bare whitespace/underscore gap names a range only when those are
          # the filename's only two dates; with a third date, which adjacent
          # pair is the period would be a guess.
          next if matches.size > 2 && gap.match?(WEAK_RANGE_GAP)

          start_on = parse_date(first[0], date_format: date_format)
          end_on = parse_date(second[0], date_format: date_format)
          next if start_on.nil? || end_on.nil?

          start_on, end_on = [ start_on, end_on ].minmax
          return FilenamePeriod.new(start_on: start_on, end_on: end_on,
                                    kind: :range, anchor_on: end_on)
        end
        nil
      end

      # Every date token with its position. The range check looks at the text
      # BETWEEN two adjacent tokens, which is what distinguishes a range from
      # unrelated dates.
      def date_matches(basename)
        matches = []
        basename.scan(DATE_TOKEN) { matches << Regexp.last_match }
        matches
      end

      def parse_month_from_filename(basename)
        match = basename.match(MONTH_PATTERN)
        return nil unless match

        year = (match[:year_first] || match[:year_second]).to_i
        month = if match[:month_first]
          match[:month_first].to_i
        else
          Date::ABBR_MONTHNAMES.index(match[:month_name][0, 3].capitalize)
        end

        date = Date.new(year, month, 1)
        reasonable_date?(date) ? date : nil
      rescue Date::Error, NoMethodError
        nil
      end

      def reasonable_date?(date)
        Import.reasonable_date_range.cover?(date)
      end
    end
end
