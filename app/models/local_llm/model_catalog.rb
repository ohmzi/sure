# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# Lists the models a local OpenAI-compatible server (Ollama, LM Studio,
# llama.cpp, vLLM) currently has installed. Mirrors
# Assistant::External::ModelCatalog's Net::HTTP shape, but for the base-URL
# world: normalize whatever the user typed to {scheme}://{host}[:port]/v1/models,
# and fall back to Ollama's native /api/tags so a native-only server still lists.
#
# Every connection/TLS/parse failure is wrapped as a typed Error carrying a
# `kind` (:timeout, :refused, :bad_status, :invalid_body, :invalid_url) so a
# discovery pass can report an honest, per-candidate diagnosis instead of a
# generic "unavailable".
class LocalLlm::ModelCatalog
  class Error < StandardError
    attr_reader :kind

    def initialize(message, kind: :unknown)
      super(message)
      @kind = kind
    end
  end

  CONNECTION_KINDS = {
    Timeout::Error => :timeout,
    Errno::ETIMEDOUT => :timeout,
    Errno::ECONNREFUSED => :refused,
    Errno::EHOSTUNREACH => :refused,
    Errno::ENETUNREACH => :refused,
    Errno::ECONNRESET => :refused,
    SocketError => :refused,
    OpenSSL::SSL::SSLError => :refused,
    EOFError => :refused,
    IOError => :refused,
    SystemCallError => :refused
  }.freeze

  def initialize(base_url:, token: nil, open_timeout: 1.5, read_timeout: 2.5)
    @base_url = base_url
    @token = token
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def models
    fetch_openai_models
  rescue Error => openai_error
    begin
      fetch_ollama_models
    rescue Error
      # Prefer the primary endpoint's diagnosis: on a non-Ollama server the
      # /v1/models failure is the informative one.
      raise openai_error
    end
  end

  private
    def fetch_openai_models
      parse_list(get("/v1/models"), "data")
    end

    def fetch_ollama_models
      parse_list(get("/api/tags"), "models")
    end

    def parse_list(body, key)
      payload = JSON.parse(body)
      entries = payload.is_a?(Hash) ? payload[key] : nil
      raise bad_body unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }

      entries.filter_map do |model|
        id = (key == "data" ? model["id"] : model["name"]).to_s
        next if id.blank?

        { id: id, label: id }
      end
    rescue JSON::ParserError
      raise bad_body
    end

    def get(suffix)
      uri = build_uri(suffix)
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@token}" if @token.present?
      request["Accept"] = "application/json"

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise Error.new("Local model server returned HTTP #{response.code}.", kind: :bad_status)
      end

      response.body
    rescue URI::InvalidURIError
      raise Error.new("The local endpoint must be an http(s) URL.", kind: :invalid_url)
    rescue *CONNECTION_KINDS.keys => e
      raise Error.new("Local model server is unreachable: #{e.message}", kind: CONNECTION_KINDS.fetch(e.class, :refused))
    end

    def bad_body
      Error.new("Local model server returned an invalid response.", kind: :invalid_body)
    end

    def build_uri(suffix)
      uri = parse_uri(@base_url)
      uri.path = "#{base_path(uri)}#{suffix}"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def parse_uri(value)
      uri = URI(value.to_s)
      raise URI::InvalidURIError, "only HTTP and HTTPS endpoints are supported" unless uri.is_a?(URI::HTTP)

      uri
    end

    # Drop a trailing "/v1" so both "http://host:11434" and "http://host:11434/v1"
    # normalize to the same "/v1/models" (a reverse-proxy prefix like "/ollama"
    # is preserved).
    def base_path(uri)
      uri.path.to_s.sub(%r{/v1/?\z}, "").sub(%r{/\z}, "")
    end
end
