# frozen_string_literal: true

require "uri"

# Finds a running local OpenAI-compatible server and lists its installed
# models, so the settings panel can offer a picker instead of asking the user
# to type an address and a model id.
#
# Detection runs ON DEMAND (never on page load): on this box the Docker-to-host
# hop to host.docker.internal:11434 can be dropped by the host firewall, and a
# synchronous probe during `show` would stall the whole settings page. Each
# candidate gets a tight per-attempt timeout, and a total wall-clock budget
# bounds the whole sweep, so the request can never hang. When nothing answers,
# NotFound carries a per-candidate diagnosis the UI can show honestly.
class LocalLlm::Discovery
  class NotFound < StandardError
    attr_reader :attempts

    def initialize(attempts)
      @attempts = attempts
      super("no local model server responded")
    end
  end

  Result = Struct.new(:base_url, :server, :models, keyword_init: true)

  # Ordered, most-likely-first. host.docker.internal reaches the host from the
  # app container; `ollama` is this project's own compose service name
  # (compose.example.ai.yml); localhost covers a host-run app.
  DEFAULT_CANDIDATES = [
    "http://host.docker.internal:11434/v1",
    "http://host.docker.internal:1234/v1",
    "http://host.docker.internal:8080/v1",
    "http://host.docker.internal:8000/v1",
    "http://ollama:11434/v1",
    "http://localhost:11434/v1"
  ].freeze

  OPEN_TIMEOUT = 1.5
  READ_TIMEOUT = 2.5
  DEFAULT_BUDGET = 8.0

  SERVER_PORTS = { 11_434 => :ollama, 1234 => :lm_studio, 8080 => :llama_cpp, 8000 => :vllm }.freeze

  def initialize(base_url: nil, token: nil, catalog: LocalLlm::ModelCatalog, candidates: DEFAULT_CANDIDATES,
                 total_budget: DEFAULT_BUDGET, clock: nil)
    @base_url = base_url.to_s.strip.presence
    @token = token.presence || Setting.local_llm_token.presence || Setting::LOCAL_LLM_PLACEHOLDER_TOKEN
    @catalog = catalog
    @candidates = candidates
    @total_budget = total_budget.to_f
    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  end

  def call
    deadline = @clock.call + @total_budget
    attempts = []
    empty = nil

    candidate_list.each do |base_url|
      remaining = deadline - @clock.call
      if remaining <= 0
        attempts << { url: base_url, outcome: :timeout, detail: "detection time budget exhausted before probe" }
        next
      end

      begin
        models = probe(base_url, remaining)
        if models.empty?
          empty ||= Result.new(base_url: base_url, server: classify(base_url), models: [])
        else
          return Result.new(base_url: base_url, server: classify(base_url), models: models)
        end
      rescue LocalLlm::ModelCatalog::Error => e
        attempts << { url: base_url, outcome: e.kind, detail: e.message }
      end
    end

    return empty if empty

    raise NotFound, attempts
  end

  private
    def probe(base_url, remaining)
      @catalog.new(
        base_url: base_url,
        token: @token,
        open_timeout: [ OPEN_TIMEOUT, remaining ].min,
        read_timeout: [ READ_TIMEOUT, remaining ].min
      ).models
    end

    def candidate_list
      [ @base_url, *@candidates ].compact_blank.map { |url| url.to_s.strip }.reject(&:blank?).uniq
    end

    def classify(base_url)
      uri = URI(base_url.to_s)
      host = uri.host.to_s.downcase
      return :ollama if host == "ollama" || host.end_with?(".ollama")

      SERVER_PORTS[uri.port] || :custom_openai_compatible
    rescue URI::InvalidURIError
      :custom_openai_compatible
    end
end
