require "test_helper"

# Every stop says what happened in context and offers the button that fixes it
# (spec §6) — the owner's June upload showed "needs your attention" and nothing
# to act on.
class DocumentHoldTest < ActiveSupport::TestCase
  setup do
    DocumentReaderLadder.stubs(:for).with(mode: "local").returns([ :local_reader ])
    DocumentReaderLadder.stubs(:for).with(mode: "online").returns([ :deepseek_reader ])
  end

  def attempt(reader, outcome, detail = nil)
    { "reader" => reader, "kind" => "cloud", "outcome" => outcome, "detail" => detail }.compact
  end

  test "a ladder failure names each reader and why, in plain words" do
    hold = DocumentHold.for_attempts([
      attempt("the local model (qwen2.5vl:7b)", "skipped_busy"),
      attempt("DeepSeek", "failed", "AI provider failed: the server responded with status 503"),
      attempt("Gemini", "failed", "AI provider failed: the server responded with status 429"),
      attempt("Other", "timed_out")
    ])

    assert_equal "all_readers_failed", hold.code
    assert_equal "read", hold.step
    assert hold.message.start_with?("The local model (qwen2.5vl:7b) was skipped because the GPU was busy with another model")
    assert_includes hold.message, "DeepSeek is overloaded right now"
    assert_includes hold.message, "Gemini is out of quota"
    assert_includes hold.message, "Other took longer than its time limit"
    assert hold.message.end_with?("Nothing was imported.")
    assert_not_includes hold.message, "status 503", "raw provider text stays in the log"
    assert_equal %w[retry_local retry_online], hold.actions
  end

  test "a read skipped only because the GPU was busy says so" do
    hold = DocumentHold.for_attempts([ attempt("the local model (qwen2.5vl:7b)", "skipped_busy") ])

    assert_equal "gpu_busy", hold.code
    assert_includes hold.actions, "retry_local"
  end

  test "rows that never added up say so" do
    hold = DocumentHold.for_attempts([ attempt("DeepSeek", "did_not_add_up") ])

    assert_includes hold.message, "DeepSeek's transactions did not add up to the statement's totals"
  end

  test "with no reader configured the action is the settings page" do
    DocumentReaderLadder.stubs(:for).with(mode: "local").returns([])
    DocumentReaderLadder.stubs(:for).with(mode: "online").returns([])

    hold = DocumentHold.for_attempts([])

    assert_equal "no_reader_configured", hold.code
    assert_equal %w[open_settings], hold.actions
  end

  test "an action with no reader behind it is not offered" do
    DocumentReaderLadder.stubs(:for).with(mode: "online").returns([])

    hold = DocumentHold.for_attempts([ attempt("the local model (m)", "failed") ])

    assert_equal %w[retry_local], hold.actions
  end

  test "a hold survives a round trip through its stored form" do
    hold = DocumentHold.for_attempts([ attempt("DeepSeek", "failed") ])

    assert_equal hold, DocumentHold.from_h(hold.to_h.as_json)
  end

  test "a named hold carries its own copy and actions" do
    hold = DocumentHold.named("statement_drift", message: "We couldn't balance this statement.")

    assert_equal "statement_drift", hold.code
    assert_equal "We couldn't balance this statement.", hold.message
    assert_equal %w[retry_online], hold.actions
  end
end
