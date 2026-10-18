require "test_helper"

# P1.11: the stored period is a fact the owner may have corrected, and the
# filename/printed period are independent witnesses. A disagreement is a
# WARNING on the statement, never a silent correction of what is stored.
class AccountStatement::PeriodCheckTest < ActiveSupport::TestCase
  test "does not warn when the stored period matches the printed period" do
    statement = statement_with(
      "statement.pdf",
      period_start_on: Date.new(2026, 4, 1),
      period_end_on: Date.new(2026, 4, 30),
      printed: [ Date.new(2026, 4, 1), Date.new(2026, 4, 30) ]
    )

    assert_not statement.period_looks_wrong?
    assert_nil statement.period_warning
    assert_nil statement.period_warning_message
  end

  test "warns when the stored period differs from the printed period" do
    statement = statement_with(
      "statement.pdf",
      period_start_on: Date.new(2026, 4, 2),
      period_end_on: Date.new(2026, 5, 1),
      printed: [ Date.new(2026, 4, 1), Date.new(2026, 4, 30) ]
    )

    assert statement.period_looks_wrong?
    warning = statement.period_warning
    assert_equal :printed, warning.source
    assert_equal Date.new(2026, 4, 1), warning.expected_start_on
    assert_equal Date.new(2026, 4, 30), warning.expected_end_on
    assert_includes statement.period_warning_message, "does not match"
    assert_includes statement.period_warning_message, "printed"
  end

  test "does not warn when the filename has no usable date and no printed period was recorded" do
    statement = statement_with(
      "statement.pdf",
      period_start_on: Date.new(2026, 4, 2),
      period_end_on: Date.new(2026, 5, 1)
    )

    assert_not statement.period_looks_wrong?
  end

  test "does not warn when no period is stored" do
    statement = statement_with(
      "statement-2026-05-09-to-2026-06-08.pdf",
      period_start_on: nil,
      period_end_on: nil
    )

    assert_not statement.period_looks_wrong?
  end

  test "matches a two-date filename period" do
    statement = statement_with(
      "statement-2026-05-09-to-2026-06-08.pdf",
      period_start_on: Date.new(2026, 5, 9),
      period_end_on: Date.new(2026, 6, 8)
    )

    assert_not statement.period_looks_wrong?
  end

  test "warns when the stored period differs from a two-date filename period" do
    statement = statement_with(
      "statement-2026-05-09-to-2026-06-08.pdf",
      period_start_on: Date.new(2026, 5, 10),
      period_end_on: Date.new(2026, 6, 8)
    )

    assert statement.period_looks_wrong?
    warning = statement.period_warning
    assert_equal :filename, warning.source
    assert_equal Date.new(2026, 5, 9), warning.expected_start_on
    assert_equal Date.new(2026, 6, 8), warning.expected_end_on
    assert_includes statement.period_warning_message, "filename"
  end

  test "treats a single filename date as an anchor inside the stored period" do
    inside = statement_with(
      "statement-2026-06-08.pdf",
      period_start_on: Date.new(2026, 5, 9),
      period_end_on: Date.new(2026, 6, 8)
    )
    assert_not inside.period_looks_wrong?

    outside = statement_with(
      "statement-2026-06-08.pdf",
      period_start_on: Date.new(2026, 4, 1),
      period_end_on: Date.new(2026, 4, 30)
    )
    assert outside.period_looks_wrong?
    assert_equal :filename, outside.period_warning.source
    assert_equal Date.new(2026, 6, 8), outside.period_warning.expected_start_on
    assert_equal Date.new(2026, 6, 8), outside.period_warning.expected_end_on
  end

  test "accepts a month-name filename whose month touches either end of the period" do
    april_start = statement_with(
      "statement April 2026.pdf",
      period_start_on: Date.new(2026, 4, 13),
      period_end_on: Date.new(2026, 5, 12)
    )
    may_end = statement_with(
      "statement May 2026.pdf",
      period_start_on: Date.new(2026, 4, 13),
      period_end_on: Date.new(2026, 5, 12)
    )

    assert_not april_start.period_looks_wrong?
    assert_not may_end.period_looks_wrong?
  end

  test "warns when a month-name filename is nowhere near the stored period" do
    statement = statement_with(
      "statement April 2026.pdf",
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30)
    )

    assert statement.period_looks_wrong?
    assert_equal :filename, statement.period_warning.source
    assert_equal Date.new(2026, 4, 1), statement.period_warning.expected_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_warning.expected_end_on
  end

  test "reports the printed period first when both witnesses disagree" do
    statement = statement_with(
      "statement-2026-05-09-to-2026-06-08.pdf",
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30),
      printed: [ Date.new(2026, 5, 9), Date.new(2026, 6, 8) ]
    )

    assert_equal :printed, statement.period_warning.source
    assert_equal [ Date.new(2026, 5, 9), Date.new(2026, 6, 8) ],
                 [ statement.period_warning.expected_start_on, statement.period_warning.expected_end_on ]
  end

  test "warns when only the stored end differs from a two-date filename" do
    statement = statement_with(
      "statement-2026-05-09-to-2026-06-08.pdf",
      period_start_on: Date.new(2026, 5, 9),
      period_end_on: Date.new(2026, 6, 7)
    )

    assert statement.period_looks_wrong?
    assert_equal :filename, statement.period_warning.source
    assert_equal Date.new(2026, 6, 8), statement.period_warning.expected_end_on
  end

  # Date.parse reads "05-06-2026" day-first, so a US statement downloaded as
  # 05-06 (May 6) was warned against as if it were June 5. The family's own
  # date format is the authority for ambiguous numeric tokens.
  test "reads ambiguous numeric filename dates in the family's US format" do
    may = statement_with(
      "statement 05-06-2026.pdf",
      period_start_on: Date.new(2026, 5, 1),
      period_end_on: Date.new(2026, 5, 31)
    )
    assert_not may.period_looks_wrong?, "05-06-2026 is May 6 in a US family"

    june = statement_with(
      "statement 05-06-2026.pdf",
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30)
    )
    assert june.period_looks_wrong?, "May 6 is outside June"
  end

  test "uses a day-first family format for ambiguous numeric filename dates" do
    family = families(:dylan_family)
    family.update_columns(date_format: "%d-%m-%Y")

    statement = statement_with(
      "statement 05-06-2026.pdf",
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30),
      family: family
    )

    assert_not statement.period_looks_wrong?, "05-06-2026 is June 5 in a day-first family"
  end

  test "matches a US-format two-date filename range" do
    statement = statement_with(
      "statement-04-13-2026-to-05-12-2026.pdf",
      period_start_on: Date.new(2026, 4, 13),
      period_end_on: Date.new(2026, 5, 12)
    )

    assert_not statement.period_looks_wrong?
  end

  # A download timestamp is not a period boundary. Multiple unrelated dates
  # must never be read as a range merely because there are two of them.
  test "does not treat a download date as the period end" do
    statement = statement_with(
      "statement-2026-05-09-downloaded-2026-10-18.pdf",
      period_start_on: Date.new(2026, 5, 9),
      period_end_on: Date.new(2026, 6, 8)
    )

    assert_not statement.period_looks_wrong?
  end

  test "ignores malformed detected periods" do
    malformed_periods = [
      "junk",
      [ "2026-04-01", "2026-04-30" ],
      { "start_on" => "2026-04-01" },
      { "start_on" => "not-a-date", "end_on" => "2026-04-30" },
      { "start_on" => nil, "end_on" => nil }
    ]

    malformed_periods.each do |detected_period|
      statement = statement_with(
        "statement.pdf",
        period_start_on: Date.new(2026, 5, 1),
        period_end_on: Date.new(2026, 5, 31),
        detected_period: detected_period
      )

      assert_not statement.period_looks_wrong?, "no warning for #{detected_period.inspect}"
    end
  end

  private
    def statement_with(filename, period_start_on:, period_end_on:, printed: nil,
                       detected_period: nil, family: families(:dylan_family))
      output = if detected_period
        { "detected_period" => detected_period }
      elsif printed
        {
          "detected_period" => {
            "start_on" => printed.first.iso8601,
            "end_on" => printed.last.iso8601,
            "source" => "pdf_text"
          }
        }
      else
        {}
      end

      AccountStatement.new(
        family: family,
        filename: filename,
        content_type: "application/pdf",
        period_start_on: period_start_on,
        period_end_on: period_end_on,
        sanitized_parser_output: output
      )
    end
end
