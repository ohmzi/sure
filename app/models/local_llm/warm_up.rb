# frozen_string_literal: true

# Loads the local model on demand (the owner, 2026-10-19: System health had
# "no button or worker or script to fix the local LLM"). A one-token chat
# completion is the one request every OpenAI-compatible server answers by
# loading the model — Ollama, LM Studio, llama.cpp alike — so the next real
# call does not pay the load time inside its own timeout.
#
# It never fights the GPU: already loaded means done, and another model in
# use (LocalLlm::GpuGuard) means "busy" rather than queueing behind it. The
# server's own keep-alive unloads the model again afterwards.
#
# Returns { status:, message: } — loaded, busy, unreachable, missing_model or
# failed — and records the last outcome for the System health page.
class LocalLlm::WarmUp
  CACHE_KEY = "local_llm/warm_up/last"

  class << self
    def available?
      Setting.llm_provider.to_s == "local" && Setting.local_llm_model.present?
    end

    def call
      new.call
    end

    def request!
      Rails.cache.write(CACHE_KEY, { status: "loading", at: Time.current })
      LocalLlmWarmUpJob.perform_later
    end

    def last
      Rails.cache.read(CACHE_KEY)
    end
  end

  def initialize
    @base_url = (Setting.local_llm_base_url.presence || Setting::LOCAL_LLM_DEFAULT_BASE_URL).to_s.sub(%r{/+\z}, "")
    @model = Setting.local_llm_model.to_s
    @token = Setting.local_llm_token.presence || Setting::LOCAL_LLM_PLACEHOLDER_TOKEN
  end

  def call
    record(outcome)
  end

  private
    attr_reader :base_url, :model, :token

    def outcome
      guard = LocalLlm::GpuGuard.new(base_url: base_url, model: model)
      return { status: "loaded" } if guard.loaded?
      return { status: "busy" } if guard.busy?

      response = connection.post("chat/completions") do |request|
        request.body = { model: model, messages: [ { role: "user", content: "ok" } ], max_tokens: 1 }.to_json
      end

      if response.success?
        { status: "loaded" }
      elsif response.status == 404 || response.body.to_s.match?(/not found|no such model/i)
        failure("missing_model", "HTTP #{response.status}")
      else
        failure("failed", "HTTP #{response.status}")
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, SocketError, Errno::ECONNREFUSED => e
      failure("unreachable", e.message)
    rescue StandardError => e
      failure("failed", "#{e.class}: #{e.message}")
    end

    def connection
      Faraday.new(url: "#{base_url}/", request: { timeout: Setting.local_llm_call_timeout, open_timeout: 5 }) do |faraday|
        faraday.headers["Content-Type"] = "application/json"
        faraday.headers["Authorization"] = "Bearer #{token}"
      end
    end

    def failure(status, detail)
      DebugLogEntry.capture(
        category: "ai_health",
        level: "error",
        message: "Loading the local model failed (#{status})",
        source: self.class.name,
        provider_key: "local_llm",
        metadata: { endpoint: AiHealth.redact_endpoint(base_url), model: model, status: status, detail: detail.to_s.first(300) }
      )
      { status: status, message: detail.to_s.first(300) }
    end

    def record(result)
      Rails.cache.write(CACHE_KEY, result.merge(at: Time.current))
      result
    end
end
