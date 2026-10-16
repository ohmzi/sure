# frozen_string_literal: true

require "net/http"

# Keeps a document read from fighting another workload for the GPU, and from
# leaving its model resident after the read ends.
#
# The local endpoint is usually Ollama, shared with other workloads on the same
# card. Before a read, `busy?` asks Ollama what is loaded: when another model is
# resident and still inside its keep-alive (so in use) and ours is not, loading
# ours would queue behind it — the June statement waited ~2 hours that way.
# After a read, `unload!` drops our model at once instead of leaving it to the
# server's keep-alive.
#
# Both answer conservatively on anything unexpected: a server that is not Ollama
# (LM Studio, vLLM) has no /api/ps, so it is "not busy" and unload is a no-op.
class LocalLlm::GpuGuard
  TIMEOUT = 5

  def initialize(base_url:, model:)
    @origin = base_url.to_s.strip.sub(%r{/+\z}, "").sub(%r{/v1\z}, "")
    @model = model.to_s
  end

  def busy?
    loaded = JSON.parse(request(Net::HTTP::Get, "/api/ps")).fetch("models", [])
    return false if loaded.any? { |entry| same_model?(entry) }

    loaded.any? { |entry| in_use?(entry) }
  rescue StandardError => e
    Rails.logger.info("LocalLlm::GpuGuard busy check skipped (#{e.class}): treating the GPU as free")
    false
  end

  def unload!
    request(Net::HTTP::Post, "/api/generate", { model: @model, keep_alive: 0 }.to_json)
    true
  rescue StandardError => e
    Rails.logger.info("LocalLlm::GpuGuard could not unload #{@model} (#{e.class})")
    false
  end

  private
    def same_model?(entry)
      [ entry["name"], entry["model"] ].include?(@model)
    end

    def in_use?(entry)
      expires_at = Time.zone.parse(entry["expires_at"].to_s)
      expires_at.present? && expires_at.future?
    rescue ArgumentError
      false
    end

    def request(verb, path, body = nil)
      uri = URI.parse("#{@origin}#{path}")
      http_request = verb.new(uri.request_uri, "Content-Type" => "application/json")
      http_request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(http_request)
      end
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
end
