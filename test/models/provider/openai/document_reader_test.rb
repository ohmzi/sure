# frozen_string_literal: true

require "test_helper"

class Provider::Openai::DocumentReaderTest < ActiveSupport::TestCase
  # The HEREDOC wraps at ~80 columns, so assert on the squished prompt: what
  # matters is the instruction, not where the line broke.
  def prompt = Provider::Openai::DocumentReader::INSTRUCTIONS.squish

  test "the prompt puts every statement row in transactions and empties line_items" do
    # The live local model filed a statement's rows under line_items, leaving
    # transactions empty, so a statement's rows were silently discarded. The
    # prompt must leave no room for that reading: the rows belong in transactions,
    # and line_items is empty for a statement.
    assert_includes prompt, "EVERY account row belongs here"
    assert_includes prompt, "one entry per line of the statement's transaction table"
    assert_includes prompt, "a statement's rows always carry a date"
    assert_includes prompt, "For a STATEMENT this MUST be an empty array"
  end
end
