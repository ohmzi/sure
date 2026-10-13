require "test_helper"

class LocalLlm::DiscoveryTest < ActiveSupport::TestCase
  # A catalog stand-in: Discovery.new(catalog:) is expected to answer `.new(...)`
  # with an object exposing `#models`, so the fake mirrors that seam and records
  # every probe (url + token) for assertions.
  class RecordingCatalog
    attr_reader :calls

    def initialize(responders)
      @responders = responders
      @calls = []
    end

    def new(base_url:, token:, **)
      Entry.new(@responders, @calls, base_url, token)
    end

    class Entry
      def initialize(responders, calls, base_url, token)
        @responders = responders
        @calls = calls
        @base_url = base_url
        @token = token
      end

      def models
        @calls << { base_url: @base_url, token: @token }
        outcome = @responders[@base_url]
        raise outcome if outcome.is_a?(Exception)

        Array(outcome)
      end
    end
  end

  teardown do
    Setting.local_llm_token = nil
    Setting.openai_access_token = nil
  end

  test "the first candidate that lists models wins, in probe order" do
    catalog = RecordingCatalog.new(
      "http://a:11434/v1" => [],
      "http://b:11434/v1" => [ { id: "qwen2.5vl:3b" } ],
      "http://c:11434/v1" => [ { id: "should-not-be-reached" } ]
    )

    result = LocalLlm::Discovery.new(
      candidates: %w[http://a:11434/v1 http://b:11434/v1 http://c:11434/v1],
      catalog: catalog,
      token: "tok"
    ).call

    assert_equal "http://b:11434/v1", result.base_url
    assert_equal "qwen2.5vl:3b", result.models.first[:id]
    assert_equal %w[http://a:11434/v1 http://b:11434/v1], catalog.calls.map { |c| c[:base_url] }
  end

  test "a reachable but empty server is surfaced, not treated as a failure" do
    catalog = RecordingCatalog.new("http://only:11434/v1" => [])

    result = LocalLlm::Discovery.new(
      candidates: [ "http://only:11434/v1" ],
      catalog: catalog,
      token: "tok"
    ).call

    assert_equal "http://only:11434/v1", result.base_url
    assert_equal [], result.models
  end

  test "a submitted base url is probed before the defaults" do
    catalog = RecordingCatalog.new(
      "http://typed:11434/v1" => [ { id: "qwen2.5vl:3b" } ],
      "http://default:11434/v1" => [ { id: "default-model" } ]
    )

    result = LocalLlm::Discovery.new(
      base_url: "http://typed:11434/v1",
      candidates: [ "http://default:11434/v1" ],
      catalog: catalog,
      token: "tok"
    ).call

    assert_equal "http://typed:11434/v1", result.base_url
    assert_equal "http://typed:11434/v1", catalog.calls.first[:base_url]
  end

  test "all candidates failing raises NotFound carrying every attempt and its outcome" do
    catalog = RecordingCatalog.new(
      "http://a:11434/v1" => LocalLlm::ModelCatalog::Error.new("no answer", kind: :timeout),
      "http://b:11434/v1" => LocalLlm::ModelCatalog::Error.new("nothing listening", kind: :refused)
    )

    error = assert_raises(LocalLlm::Discovery::NotFound) do
      LocalLlm::Discovery.new(
        candidates: %w[http://a:11434/v1 http://b:11434/v1],
        catalog: catalog,
        token: "tok"
      ).call
    end

    assert_equal %w[http://a:11434/v1 http://b:11434/v1], error.attempts.map { |a| a[:url] }
    assert_equal %i[timeout refused], error.attempts.map { |a| a[:outcome] }
  end

  test "never sends the cloud key — a real request carries the local placeholder token" do
    Setting.openai_access_token = "cloud-secret-key"
    Setting.local_llm_token = nil

    request = stub_request(:get, "http://localhost:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer #{Setting::LOCAL_LLM_PLACEHOLDER_TOKEN}" })
      .to_return(status: 200, body: { object: "list", data: [ { id: "qwen2.5vl:3b" } ] }.to_json)

    result = LocalLlm::Discovery.new(candidates: [ "http://localhost:11434/v1" ]).call

    assert_requested request
    assert_equal "qwen2.5vl:3b", result.models.first[:id]
  end

  test "honors the total wall-clock budget and never probes past it" do
    catalog = RecordingCatalog.new(
      "http://a:11434/v1" => LocalLlm::ModelCatalog::Error.new("no answer", kind: :timeout)
    )
    # deadline=0, first probe at 0 (in budget), then the clock jumps past it.
    ticks = [ 0.0, 0.0, 99.0, 99.0, 99.0, 99.0 ]
    clock = -> { ticks.shift || 99.0 }

    error = assert_raises(LocalLlm::Discovery::NotFound) do
      LocalLlm::Discovery.new(
        candidates: %w[http://a:11434/v1 http://b:11434/v1 http://c:11434/v1],
        catalog: catalog,
        token: "tok",
        total_budget: 8.0,
        clock: clock
      ).call
    end

    assert_equal 1, catalog.calls.size, "no candidate may be probed after the budget is spent"
    assert_equal 3, error.attempts.size
    assert_match(/budget/i, error.attempts.last[:detail].to_s)
  end

  test "classifies the server by port and host" do
    settings = LocalLlm::Discovery.new(candidates: [], catalog: RecordingCatalog.new({}), token: "tok")

    assert_equal :ollama, settings.send(:classify, "http://host.docker.internal:11434/v1")
    assert_equal :ollama, settings.send(:classify, "http://ollama:11434/v1")
    assert_equal :lm_studio, settings.send(:classify, "http://host.docker.internal:1234/v1")
    assert_equal :llama_cpp, settings.send(:classify, "http://host.docker.internal:8080/v1")
    assert_equal :vllm, settings.send(:classify, "http://host.docker.internal:8000/v1")
    assert_equal :custom_openai_compatible, settings.send(:classify, "http://host.docker.internal:9999/v1")
  end
end
