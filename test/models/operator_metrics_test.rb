require "test_helper"

class OperatorMetricsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @now = Time.current
  end

  test "reports the LLM provider error rate from recorded usage rows" do
    record_llm_call
    record_llm_call(provider: "anthropic")
    record_llm_call(provider: "anthropic", error: "rate limited", status: 429)

    metrics = OperatorMetrics.new(@family, now: @now)

    assert_equal 3, metrics.llm_calls
    assert_equal 1, metrics.llm_failures
    assert_in_delta 1.0 / 3, metrics.provider_error_rate
  end

  test "reports no error rate when no provider call was recorded" do
    metrics = OperatorMetrics.new(@family, now: @now)

    assert_equal 0, metrics.llm_calls
    assert_nil metrics.provider_error_rate
  end

  test "ignores provider calls outside the window" do
    record_llm_call(created_at: 30.days.ago)
    record_llm_call(error: "rate limited", created_at: 30.days.ago)
    record_llm_call

    metrics = OperatorMetrics.new(@family, now: @now)

    assert_equal 1, metrics.llm_calls
    assert_equal 0, metrics.llm_failures
  end

  test "does not invent a provider latency" do
    record_llm_call

    metrics = OperatorMetrics.new(@family, now: @now)

    assert_not metrics.provider_latency_available?
    assert_nil metrics.provider_latency_seconds
  end

  test "summarizes upload-to-published duration for completed imports" do
    record_import(created_at: 10.minutes.ago, updated_at: 8.minutes.ago)
    record_import(created_at: 20.minutes.ago, updated_at: 17.minutes.ago)
    record_import(status: "failed", created_at: 1.hour.ago, updated_at: 10.minutes.ago)

    latency = OperatorMetrics.new(@family, now: @now).import_latency

    assert_equal 2, latency[:samples]
    assert_in_delta 2.5.minutes, latency[:average_seconds]
    assert_in_delta 3.minutes, latency[:max_seconds]
  end

  test "reports no import latency without a completed import in the window" do
    record_import(created_at: 30.days.ago, updated_at: 30.days.ago)

    assert_nil OperatorMetrics.new(@family, now: @now).import_latency
  end

  private
    def record_llm_call(provider: "openai", error: nil, status: nil, created_at: nil)
      metadata = {}
      if error
        metadata[:error] = error
        metadata[:http_status_code] = status
      end
      usage = @family.llm_usages.create!(
        provider: provider, model: "gpt-4.1", operation: "chat",
        prompt_tokens: 0, completion_tokens: 0, total_tokens: 0,
        metadata: metadata
      )
      usage.update_columns(created_at: created_at) if created_at
      usage
    end

    def record_import(status: "complete", created_at:, updated_at:)
      import = TransactionImport.create!(family: @family, status: status)
      import.update_columns(created_at: created_at, updated_at: updated_at)
      import
    end
end
