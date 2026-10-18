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

  private
    def statement_with(filename, period_start_on:, period_end_on:, printed: nil)
      output = if printed
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
        family: families(:dylan_family),
        filename: filename,
        content_type: "application/pdf",
        period_start_on: period_start_on,
        period_end_on: period_end_on,
        sanitized_parser_output: output
      )
    end
end
