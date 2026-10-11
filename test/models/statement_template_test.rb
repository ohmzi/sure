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
      this line is not a transaction
    TXT

    assert_equal [], StatementTemplate.detect(text).rows(text)
  end
end
