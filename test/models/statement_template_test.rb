require "test_helper"

class StatementTemplateTest < ActiveSupport::TestCase
  def chase_text
    file_fixture("imports/chase_statement.txt").read
  end

  test "detects the Chase template from its header" do
    template = StatementTemplate.detect(chase_text)

    assert_instance_of StatementTemplate::Bank::Chase, template
    assert_equal 1, template.version
    assert_equal "chase", template.bank_key
  end

  test "returns nil for an unrecognized bank" do
    assert_nil StatementTemplate.detect("First National Bank of Nowhere\nSome random rows")
    assert_nil StatementTemplate.detect("")
    assert_nil StatementTemplate.detect(nil)
  end

  test "rows parses only lines that match the statement layout" do
    rows = StatementTemplate.detect(chase_text).rows(chase_text)

    assert_equal 3, rows.size
    assert_equal Date.new(2024, 11, 4), rows.first.date
    assert_equal BigDecimal("-84.12"), rows.first.amount
    assert_equal "POS DEBIT WHOLE FOODS MKT #12345", rows.first.payee

    assert_equal BigDecimal("3250.00"), rows.second.amount
    assert_equal Date.new(2024, 11, 15), rows.third.date
  end

  test "rows never fabricates a row from a non-matching line" do
    text = <<~TXT
      JPMorgan Chase Bank, N.A.
      November 01, 2024 through November 30, 2024
      ACCOUNT ACTIVITY
      Date        Description                 Amount      Balance
      11/01       Beginning Balance                     5,412.33
      this line is not a transaction
      TOTAL FEES FOR THIS PERIOD                          $0.00
    TXT

    assert_equal [], StatementTemplate.detect(text).rows(text)
  end

  test "an unrecognized start month yields no rows instead of raising at a year boundary" do
    # (Ruling M2-C5, 2026-10-11 close-out): "Foo" matches the period pattern but
    # names no month, so a year-boundary statement's year inference is unusable.
    # The template must skip (emit nothing) rather than guess - before the guard
    # date_for compared Integer < nil and raised ArgumentError.
    text = <<~TXT
      JPMorgan Chase Bank, N.A.
      Foo 01, 2024 through January 31, 2025
      ACCOUNT ACTIVITY
      Date        Description                 Amount      Balance
      12/05       POS DEBIT WHOLE FOODS MKT #12345                  -84.12        5,412.33
    TXT

    assert_equal [], StatementTemplate.detect(text).rows(text)
  end

  test "skips an impossible date rather than raising" do
    # (Ruling M2-C5, 2026-10-11 close-out): a matched line whose MM/DD is not a
    # real date (for example 02/31) is dropped, never guessed at.
    text = <<~TXT
      JPMorgan Chase Bank, N.A.
      November 01, 2024 through November 30, 2024
      ACCOUNT ACTIVITY
      Date        Description                 Amount      Balance
      02/31       INTEREST CHARGE                                    -1.00        5,412.33
      11/06       ACH CREDIT ACME PAYROLL                          3,250.00       8,662.33
    TXT

    rows = StatementTemplate.detect(text).rows(text)

    assert_equal [ Date.new(2024, 11, 6) ], rows.map(&:date)
    assert_equal [ "ACH CREDIT ACME PAYROLL" ], rows.map(&:payee)
  end
end
