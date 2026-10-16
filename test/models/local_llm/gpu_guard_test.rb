require "test_helper"

# The owner's June statement waited ~2 hours in Ollama's queue because another
# workload's model held the GPU. The guard asks Ollama what is loaded before a
# read, and unloads the reading model when the read ends.
class LocalLlm::GpuGuardTest < ActiveSupport::TestCase
  BASE_URL = "http://host.docker.internal:11434/v1"
  PS_URL = "http://host.docker.internal:11434/api/ps"

  def guard = LocalLlm::GpuGuard.new(base_url: BASE_URL, model: "qwen2.5vl:7b")

  def stub_loaded(*models)
    body = { models: models.map { |name, expires_at| { name: name, model: name, size_vram: 1, expires_at: expires_at } } }
    stub_request(:get, PS_URL).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  test "busy when another model is loaded and still in use, and ours is not" do
    stub_loaded([ "qwen3.8:27b", 2.minutes.from_now.iso8601 ])

    assert guard.busy?
  end

  test "not busy when our model is already loaded" do
    stub_loaded([ "qwen3.8:27b", 2.minutes.from_now.iso8601 ], [ "qwen2.5vl:7b", 1.minute.from_now.iso8601 ])

    assert_not guard.busy?
  end

  test "not busy when the other model is past its keep-alive" do
    stub_loaded([ "qwen3.8:27b", 1.minute.ago.iso8601 ])

    assert_not guard.busy?
  end

  test "not busy when nothing is loaded" do
    stub_loaded

    assert_not guard.busy?
  end

  test "not busy on a server that is not Ollama" do
    stub_request(:get, PS_URL).to_return(status: 404, body: "not found")

    assert_not guard.busy?
  end

  test "not busy when the server cannot be reached" do
    stub_request(:get, PS_URL).to_raise(Errno::ECONNREFUSED)

    assert_not guard.busy?
  end

  test "unload asks Ollama to drop the model now" do
    unload = stub_request(:post, "http://host.docker.internal:11434/api/generate")
               .with(body: { model: "qwen2.5vl:7b", keep_alive: 0 }.to_json)
               .to_return(status: 200, body: "{}")

    assert guard.unload!
    assert_requested unload
  end

  test "unload reports false, never raises, when the server refuses" do
    stub_request(:post, "http://host.docker.internal:11434/api/generate").to_raise(Errno::ECONNREFUSED)

    assert_equal false, guard.unload!
  end

  test "a base url without /v1 is used as the origin" do
    stub_request(:get, "http://192.168.1.5:11434/api/ps").to_return(status: 200, body: { models: [] }.to_json)

    assert_not LocalLlm::GpuGuard.new(base_url: "http://192.168.1.5:11434", model: "m").busy?
  end
end
