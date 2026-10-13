require "test_helper"

# Mirrors Assistant::External::ModelCatalog's shape (Net::HTTP + webmock), but
# for the OpenAI/Ollama world: normalize a base URL to {host}/v1/models, then
# fall back to Ollama's native /api/tags so a native-only server still lists.
class LocalLlm::ModelCatalogTest < ActiveSupport::TestCase
  test "lists models from the OpenAI-compatible endpoint" do
    request = stub_request(:get, "http://host.docker.internal:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer ollama-local", "Accept" => "application/json" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: [ { id: "qwen2.5vl:3b" }, { id: "llama3.1:8b" } ] }.to_json
      )

    models = LocalLlm::ModelCatalog.new(base_url: "http://host.docker.internal:11434/v1", token: "ollama-local").models

    assert_requested request
    assert_equal %w[qwen2.5vl:3b llama3.1:8b], models.pluck(:id)
    assert_equal "qwen2.5vl:3b", models.first[:label]
  end

  test "normalizes a bare host base url to {host}/v1/models" do
    request = stub_request(:get, "http://localhost:11434/v1/models")
      .to_return(status: 200, body: { data: [ { id: "qwen2.5vl:3b" } ] }.to_json)

    models = LocalLlm::ModelCatalog.new(base_url: "http://localhost:11434").models

    assert_requested request
    assert_equal %w[qwen2.5vl:3b], models.pluck(:id)
  end

  test "keeps a path prefix when the endpoint is reverse-proxied" do
    request = stub_request(:get, "http://proxy.test/ollama/v1/models")
      .to_return(status: 200, body: { data: [ { id: "qwen2.5vl:3b" } ] }.to_json)

    LocalLlm::ModelCatalog.new(base_url: "http://proxy.test/ollama/v1").models

    assert_requested request
  end

  test "falls back to the Ollama-native tags endpoint when the OpenAI list fails" do
    stub_request(:get, "http://localhost:11434/v1/models").to_return(status: 404, body: "not found")
    tags = stub_request(:get, "http://localhost:11434/api/tags")
      .to_return(status: 200, body: { models: [ { name: "qwen2.5vl:3b" } ] }.to_json)

    models = LocalLlm::ModelCatalog.new(base_url: "http://localhost:11434/v1").models

    assert_requested tags
    assert_equal %w[qwen2.5vl:3b], models.pluck(:id)
  end

  test "an empty but valid list is not an error" do
    stub_request(:get, "http://localhost:11434/v1/models")
      .to_return(status: 200, body: { object: "list", data: [] }.to_json)

    assert_equal [], LocalLlm::ModelCatalog.new(base_url: "http://localhost:11434/v1").models
  end

  test "wraps connection failures as typed errors carrying their kind" do
    { timeout: Timeout::Error, refused: Errno::ECONNREFUSED }.each do |kind, error|
      stub_request(:get, "http://localhost:11434/v1/models").to_raise(error)
      stub_request(:get, "http://localhost:11434/api/tags").to_raise(error)

      err = assert_raises(LocalLlm::ModelCatalog::Error) do
        LocalLlm::ModelCatalog.new(base_url: "http://localhost:11434/v1").models
      end

      assert_equal kind, err.kind, "expected #{error} to map to #{kind}"
    end
  end

  test "wraps a non-2xx status as a bad_status error" do
    stub_request(:get, "http://localhost:11434/v1/models").to_return(status: 500, body: "boom")
    stub_request(:get, "http://localhost:11434/api/tags").to_return(status: 500, body: "boom")

    err = assert_raises(LocalLlm::ModelCatalog::Error) do
      LocalLlm::ModelCatalog.new(base_url: "http://localhost:11434/v1").models
    end

    assert_equal :bad_status, err.kind
  end

  test "wraps an invalid response body as an invalid_body error" do
    stub_request(:get, "http://localhost:11434/v1/models").to_return(status: 200, body: { data: { nope: true } }.to_json)
    stub_request(:get, "http://localhost:11434/api/tags").to_return(status: 200, body: { nope: true }.to_json)

    err = assert_raises(LocalLlm::ModelCatalog::Error) do
      LocalLlm::ModelCatalog.new(base_url: "http://localhost:11434/v1").models
    end

    assert_equal :invalid_body, err.kind
  end

  test "rejects a non-HTTP url as an error" do
    error = assert_raises(LocalLlm::ModelCatalog::Error) do
      LocalLlm::ModelCatalog.new(base_url: "ftp://example.com/v1").models
    end

    assert_includes error.message, "http"
  end
end
