# frozen_string_literal: true

# Read-only operational metrics for the admin system-health page, built only
# from records the app already writes. There is no metrics dependency and no
# time-series store: the window is a query, and every value below can be
# traced to a column on a row.
#
# Honesty rules (see the P1.10 fix-plan item):
# - The LLM provider error rate is real: `LlmUsage` records a successful call
#   with its token counts and a failed one with `metadata["error"]`.
# - Provider latency is NOT recorded anywhere (LlmUsage has no duration column
#   and DebugLogEntry records no timings for provider requests), so this class
#   reports it as unavailable rather than inventing one.
# - Import latency is measured from `created_at` to `updated_at` on a
#   completed import. Import has no publish-start timestamp, so this is
#   upload-to-published, not the publish job alone; the UI says so.
class OperatorMetrics
  DEFAULT_WINDOW = 7.days
  # Cap the sample so the admin page stays bounded on a large history. The
  # newest completed imports are the ones an operator cares about.
  MAX_IMPORT_SAMPLES = 500

  attr_reader :family, :window

  def initialize(family, window: DEFAULT_WINDOW, now: Time.current)
    @family = family
    @window = window
    @now = now
  end

  def llm_calls
    @llm_calls ||= llm_scope.count
  end

  # The same recorded calls the Settings LLM-usage page summarises, kept to a
  # couple of figures here so an operator watching provider health sees token
  # volume and estimated spend without leaving System Health.
  def llm_tokens
    @llm_tokens ||= llm_scope.sum(:total_tokens)
  end

  # Estimated, not billed: LlmUsage stores the price-table estimate it wrote at
  # call time. Rows without a price contribute nothing.
  def llm_estimated_cost
    @llm_estimated_cost ||= llm_scope.sum(:estimated_cost).to_f
  end

  def llm_failures
    @llm_failures ||= llm_scope.where("metadata ->> 'error' IS NOT NULL").count
  end

  def window_days = (window / 1.day).round

  # Fraction (0.0-1.0) of recorded provider calls that failed, or nil when no
  # call was recorded in the window. A rate needs a denominator: a raw error
  # count alone is not a rate.
  def provider_error_rate
    calls = llm_calls
    return nil if calls.zero?

    llm_failures.fdiv(calls)
  end

  # LlmUsage persists tokens, cost and error text, but no request duration, so
  # there is no honest latency to summarise.
  def provider_latency_available? = false
  def provider_latency_seconds = nil

  # Upload-to-published duration for imports that completed inside the window:
  # the last write to a completed import is the publish completion. Returns a
  # hash of seconds, or nil when there is nothing to measure.
  def import_latency
    return @import_latency if defined?(@import_latency)

    durations = import_scope.pluck(:created_at, :updated_at).map { |created, updated| (updated - created).to_f }
    return @import_latency = nil if durations.empty?

    sorted = durations.sort
    @import_latency = {
      samples: durations.size,
      average_seconds: durations.sum / durations.size,
      median_seconds: percentile(sorted, 0.5),
      p95_seconds: percentile(sorted, 0.95),
      max_seconds: sorted.last
    }
  end

  private
    def since = @now - window

    def llm_scope
      @llm_scope ||= family.llm_usages.where(created_at: since..)
    end

    def import_scope
      family.imports.where(status: "complete", updated_at: since..)
            .order(updated_at: :desc)
            .limit(MAX_IMPORT_SAMPLES)
    end

    def percentile(sorted, fraction)
      sorted[((sorted.length - 1) * fraction).round]
    end
end
