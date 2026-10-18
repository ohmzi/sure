# frozen_string_literal: true

# P1.11: the stored period is checked against two independent witnesses — the
# original filename and the period the statement itself printed. A disagreement
# is a WARNING, never a correction: the owner may have deliberately set the
# period, and a correction made here would silently rewrite a financial fact.
#
# A witness that cannot produce a period is silent. A filename with no usable
# date, or a statement whose text printed no period, must never manufacture a
# warning.
class AccountStatement::PeriodCheck
  Warning = Data.define(:source, :expected_start_on, :expected_end_on,
                        :actual_start_on, :actual_end_on) do
    def message
      I18n.t(
        "account_statements.period_check.message",
        source: I18n.t("account_statements.period_check.sources.#{source}"),
        expected: period_label(expected_start_on, expected_end_on),
        actual: period_label(actual_start_on, actual_end_on)
      )
    end

    private
      def period_label(start_on, end_on)
        return I18n.l(start_on, format: :long) if start_on == end_on

        "#{I18n.l(start_on, format: :long)} – #{I18n.l(end_on, format: :long)}"
      end
  end

  attr_reader :statement

  def initialize(statement)
    @statement = statement
  end

  def warning = warnings.first
  def warning? = warnings.any?

  # The printed period is the stronger witness, so it is reported first when
  # both disagree with what was stored.
  def warnings
    return [] unless stored_period?

    [ printed_warning, filename_warning ].compact
  end

  private
    def stored_period?
      statement.period_start_on.present? && statement.period_end_on.present?
    end

    def stored_period
      [ statement.period_start_on, statement.period_end_on ]
    end

    def printed_warning
      expected = printed_period
      return nil unless expected
      return nil if expected == stored_period

      warning_for(:printed, expected)
    end

    def filename_warning
      period = AccountStatement::MetadataDetector.filename_period(
        statement.filename, date_format: statement.family&.date_format
      )
      return nil unless period
      return nil if filename_matches?(period)

      warning_for(:filename, expected_period_for(period))
    end

    # A two-date filename names both boundaries exactly. A single date is only
    # an anchor that must fall inside the stored period. A month/year must
    # overlap it (a cycle may start in one month and end in the next).
    def filename_matches?(period)
      case period.kind
      when :range
        stored_period == [ period.start_on, period.end_on ]
      when :date
        statement.period_start_on <= period.anchor_on && period.anchor_on <= statement.period_end_on
      when :month
        period.start_on <= statement.period_end_on && period.end_on >= statement.period_start_on
      else
        true
      end
    end

    # A single-date warning speaks about that date, not about the month range
    # the metadata detector guesses for a missing period.
    def expected_period_for(period)
      period.kind == :date ? [ period.anchor_on, period.anchor_on ] : [ period.start_on, period.end_on ]
    end

    def printed_period
      output = statement.sanitized_parser_output.to_h
      detected = output["detected_period"]
      return nil unless detected.is_a?(Hash)

      start_on = parse_iso8601(detected["start_on"])
      end_on = parse_iso8601(detected["end_on"])
      return nil if start_on.nil? || end_on.nil?

      [ start_on, end_on ]
    end

    def parse_iso8601(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError
      nil
    end

    def warning_for(source, expected)
      Warning.new(
        source: source,
        expected_start_on: expected.first,
        expected_end_on: expected.last,
        actual_start_on: statement.period_start_on,
        actual_end_on: statement.period_end_on
      )
    end
end
