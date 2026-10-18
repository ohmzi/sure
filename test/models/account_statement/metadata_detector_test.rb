require "test_helper"

# Filename dates are a weak witness: the formats are often ambiguous, and a
# filename can carry dates that have nothing to do with the statement period
# (a download date, for one). The detector must read them with the family's
# format and must only report a range when the filename actually names one.
class AccountStatement::MetadataDetectorTest < ActiveSupport::TestCase
  test "reads a single ambiguous date in the family's format" do
    period = AccountStatement::MetadataDetector.filename_period(
      "statement 05-06-2026.pdf", date_format: "%m-%d-%Y"
    )

    assert_equal :date, period.kind
    assert_equal Date.new(2026, 5, 6), period.anchor_on

    day_first = AccountStatement::MetadataDetector.filename_period(
      "statement 05-06-2026.pdf", date_format: "%d-%m-%Y"
    )
    assert_equal Date.new(2026, 6, 5), day_first.anchor_on
  end

  test "reads a clear two-date filename as a range" do
    period = AccountStatement::MetadataDetector.filename_period(
      "statement-04-13-2026-to-05-12-2026.pdf", date_format: "%m-%d-%Y"
    )

    assert_equal :range, period.kind
    assert_equal [ Date.new(2026, 4, 13), Date.new(2026, 5, 12) ],
                 [ period.start_on, period.end_on ]
  end

  test "does not turn unrelated dates into a period range" do
    assert_nil AccountStatement::MetadataDetector.filename_period(
      "statement-2026-05-09-downloaded-2026-10-18.pdf", date_format: "%m-%d-%Y"
    )
  end

  test "reads a bare whitespace gap between two dates as a range" do
    period = AccountStatement::MetadataDetector.filename_period(
      "statement 2026-05-09 2026-06-08.pdf"
    )

    assert_equal :range, period.kind
    assert_equal [ Date.new(2026, 5, 9), Date.new(2026, 6, 8) ],
                 [ period.start_on, period.end_on ]
  end

  test "reads a bare underscore gap between two dates as a range" do
    period = AccountStatement::MetadataDetector.filename_period(
      "statement_2026-05-09_2026-06-08.pdf"
    )

    assert_equal :range, period.kind
    assert_equal [ Date.new(2026, 5, 9), Date.new(2026, 6, 8) ],
                 [ period.start_on, period.end_on ]
  end

  # A bare gap is weak evidence: with a third date in the name, which pair is
  # the period is a guess, so it stays silent (the explicit connectors still
  # name their pair).
  test "does not pair dates on a bare gap when the filename names three dates" do
    assert_nil AccountStatement::MetadataDetector.filename_period(
      "statement 2026-05-09 2026-06-08 2026-10-18.pdf"
    )
  end

  test "keeps ISO dates unambiguous without a family format" do
    iso = AccountStatement::MetadataDetector.filename_period("statement-2026-05-09.pdf")

    assert_equal :date, iso.kind
    assert_equal Date.new(2026, 5, 9), iso.anchor_on

    # Without a family format an ambiguous numeric token has no trustworthy
    # reading, so it is silent rather than guessed day-first.
    assert_nil AccountStatement::MetadataDetector.filename_period("statement-05-06-2026.pdf")
  end
end
