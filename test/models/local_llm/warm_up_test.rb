require "test_helper"

# The owner (2026-10-19): System health had no way to fix the local model.
# "Load local model" asks it for one token, which makes Ollama (or any
# OpenAI-compatible local server) load it, and says what happened.
class LocalLlm::WarmUpTest < ActiveSupport::TestCase
  setup do
    Setting.stubs(:llm_provider).returns("local")
    Setting.stubs(:local_llm_base_url).returns("http://host.docker.internal:11434/v1")
    Setting.stubs(:local_llm_model).returns("qwen2.5vl:7b")
    Setting.stubs(:local_llm_token).returns(nil)
    @ps = stub_request(:get, "http://host.docker.internal:11434/api/ps").to_return(status: 200, body: { models: [] }.to_json)
  end

  test "loading asks the local model for one token" do
    request = stub_request(:post, "http://host.docker.internal:11434/v1/chat/completions")
      .with { |req| JSON.parse(req.body).slice("model", "max_tokens") == { "model" => "qwen2.5vl:7b", "max_tokens" => 1 } }
      .to_return(status: 200, body: { choices: [ { message: { content: "ok" } } ] }.to_json)

    result = LocalLlm::WarmUp.call

    assert_requested request
    assert_equal "loaded", result[:status]
  end

  test "an unreachable server is reported with how to start it" do
    stub_request(:post, "http://host.docker.internal:11434/v1/chat/completions").to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    assert_difference "DebugLogEntry.count", 1 do
      result = LocalLlm::WarmUp.call
      assert_equal "unreachable", result[:status]
    end
  end

  test "a missing model is reported as such" do
    stub_request(:post, "http://host.docker.internal:11434/v1/chat/completions")
      .to_return(status: 404, body: { error: { message: "model \"qwen2.5vl:7b\" not found" } }.to_json)

    assert_equal "missing_model", LocalLlm::WarmUp.call[:status]
  end

  test "a model that is already loaded is left as it is" do
    stub_request(:get, "http://host.docker.internal:11434/api/ps").to_return(status: 200, body: { models: [ { name: "qwen2.5vl:7b", model: "qwen2.5vl:7b" } ] }.to_json)

    assert_equal "loaded", LocalLlm::WarmUp.call[:status]
    assert_not_requested :post, "http://host.docker.internal:11434/v1/chat/completions"
  end

  test "it is offered only when Local is selected with a model" do
    assert LocalLlm::WarmUp.available?
    Setting.stubs(:llm_provider).returns("openai")
    assert_not LocalLlm::WarmUp.available?
  end
end
