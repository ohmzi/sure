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

  # W8-D. The identity-only read is the prompt the model gets when the
  # deterministic reader has PROVEN the statement's rows. These pins are the
  # guard against a later edit silently re-mandating the row table on the
  # deterministic path.
  def identity_prompt = Provider::Openai::DocumentReader::IDENTITY_INSTRUCTIONS.squish

  test "the identity-only prompt withdraws the row request so the model never enumerates the table" do
    assert_not_includes identity_prompt, "EVERY account row belongs here",
                        "the deterministic path must not re-demand a statement's row table"
    assert_not_includes identity_prompt, "one entry per line of the statement's transaction table"
    assert_includes identity_prompt, "transactions and line_items"
    assert_includes identity_prompt, "ALREADY"
    assert_includes identity_prompt, "MUST be empty arrays"
    assert_includes identity_prompt, "not helpful"
  end

  test "both instruction variants still require every identity field" do
    fields = %w[document_class institution_name account_last4 card_last4 card_network
                currency statement_period]
    [ prompt, identity_prompt ].each do |text|
      fields.each { |field| assert_includes text, field, "#{field} must be required in both variants" }
    end
  end

  test "the two variants share a body and differ only in the row paragraph" do
    # Same shared body and tail, so the untrusted prompt is unchanged and the two
    # cannot drift apart: removing each variant's own row paragraph leaves the
    # same text behind.
    full = Provider::Openai::DocumentReader::INSTRUCTIONS
    identity = Provider::Openai::DocumentReader::IDENTITY_INSTRUCTIONS

    assert_equal full.sub(Provider::Openai::DocumentReader::ROWS_REQUESTED, ""),
                 identity.sub(Provider::Openai::DocumentReader::ROWS_ALREADY_READ, ""),
                 "the variants must differ only by their row paragraph"
  end
end
