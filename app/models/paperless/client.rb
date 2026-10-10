# frozen_string_literal: true

require "faraday/multipart"

# Faraday client for paperless-ngx 3.3.0 (REST API version 10). The token and
# base URL come from the environment; the browser never calls paperless, this
# client is the only egress.
class Paperless::Client
  DEFAULT_URL = "http://paperless:8000".freeze
  DEFAULT_TOKEN_FILE = "/run/secrets/paperless_token".freeze
  FILE_KINDS = { original: "download", preview: "preview", thumb: "thumb" }.freeze
  TASK_FAILURE_STATUSES = %w[failure revoked].freeze

  def initialize(base_url: nil, token: nil)
    @base_url = (base_url.presence || ENV["OHMZBUDGET_PAPERLESS_URL"].presence || DEFAULT_URL).to_s.chomp("/")
    @token = token.presence || resolve_token
  end

  def configured? = @token.present? && @base_url.present?

  def post_document(io:, filename:, content_type:, title:, created:, tags: [])
    response = with_errors do
      json_connection.post("/api/documents/post_document/") do |req|
        req.body = {
          document: Faraday::Multipart::FilePart.new(io, content_type, filename),
          title: title,
          created: created.to_s,
          tags: Array(tags)
        }
      end
    end
    parse_json(response) # a bare JSON string: the task uuid
  end

  def task(task_id)
    response = with_errors do
      json_connection.get("/api/tasks/", "task_id" => task_id)
    end
    body = parse_json(response)
    result = body.is_a?(Hash) ? Array(body["results"]).first : Array(body).first
    raise Paperless::Error.new("paperless returned no task for #{task_id}", code: :not_found) if result.blank?

    status = result["status"].to_s
    if TASK_FAILURE_STATUSES.include?(status)
      data = result["result_data"] || {}
      raise Paperless::Error.new("paperless task failed: #{data['error_message'] || data['reason']}", code: :task_failed)
    end

    data = result["result_data"] || {}
    Paperless::Task.new(status: status.to_sym, document_id: data["document_id"], duplicate_of: data["duplicate_of"], error_message: data["error_message"])
  end

  def document(id)
    response = with_errors { json_connection.get("/api/documents/#{id}/") }
    body = parse_json(response)
    Paperless::Document.new(id: body["id"], title: body["title"], created: body["created"],
                            tag_ids: Array(body["tags"]), content: body["content"].to_s)
  end

  # R3: ONE shape. With a block it streams `(chunk, env)`; with no block it
  # returns a buffered response whose body is a String. Both branches map HTTP
  # errors to Paperless::Error with the pinned codes.
  def file(id, kind:, range: nil, &block)
    path = FILE_KINDS.fetch(kind.to_sym) { raise ArgumentError, "unknown kind: #{kind}" }
    if block
      stream_connection.get("/api/documents/#{id}/#{path}/") do |req|
        req.headers["Range"] = range if range.present?
        # Faraday 2.14 calls on_data with (chunk, bytes, env); adapt to the
        # pinned (chunk, env) contract and map the streamed status here.
        req.options.on_data = proc { |chunk, _bytes, env| stream_chunk(env, chunk, block) }
      end
      nil
    else
      response = with_errors do
        json_connection.get("/api/documents/#{id}/#{path}/") do |req|
          req.headers["Range"] = range if range.present?
        end
      end
      # Ruling 2: Faraday::Response has no #body= (2.14.3); assign through the env.
      response.env.body = response.env.body.to_s
      response
    end
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
    raise Paperless::Error.new("paperless unreachable: #{e.message}", code: :unreachable)
  end

  def tag_id(name)
    response = with_errors { json_connection.get("/api/tags/", "name" => name) }
    body = parse_json(response)
    results = body.is_a?(Hash) ? Array(body["results"]) : Array(body)
    match = results.find { |tag| tag["name"].to_s.casecmp?(name.to_s) }
    return match["id"] if match

    created = with_errors do
      json_connection.post("/api/tags/") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(name: name)
      end
    end
    parse_json(created)["id"]
  end

  private

    # R1 resolution order: dev env override, then the mounted token file.
    def resolve_token
      ENV["OHMZBUDGET_PAPERLESS_TOKEN"].presence || token_from_file
    end

    def token_from_file
      path = ENV["OHMZBUDGET_PAPERLESS_TOKEN_FILE"].presence || DEFAULT_TOKEN_FILE
      File.read(path).strip if path && File.exist?(path)
    end

    # Maps a streamed HTTP status to the pinned error codes before any chunk is
    # handed to the caller's block.
    def stream_chunk(env, chunk, block)
      case env.status
      when 401 then raise Paperless::Error.new("paperless rejected the token", code: :unauthorized)
      when 404 then raise Paperless::Error.new("paperless resource not found", code: :not_found)
      when 500..599 then raise Paperless::Error.new("paperless error: #{env.status}", code: :bad_response)
      else block.call(chunk, env)
      end
    end

    def base_connection(raise_error:)
      Faraday.new(url: @base_url) do |f|
        f.options.open_timeout = 5
        f.options.timeout = 30
        f.request :multipart
        f.request :retry, {
          max: 3, interval: 0.5, interval_randomness: 0.5, backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        }
        f.response :raise_error if raise_error
        f.headers["Authorization"] = "Token #{@token}"
        f.headers["Accept"] = "application/json; version=10"
      end
    end

    def json_connection = @json_connection ||= base_connection(raise_error: true)
    def stream_connection = @stream_connection ||= base_connection(raise_error: false)

    def with_errors
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise Paperless::Error.new("paperless unreachable: #{e.message}", code: :unreachable)
    rescue Faraday::UnauthorizedError
      raise Paperless::Error.new("paperless rejected the token", code: :unauthorized)
    rescue Faraday::ResourceNotFound
      raise Paperless::Error.new("paperless resource not found", code: :not_found)
    rescue Faraday::ClientError, Faraday::ServerError => e
      raise Paperless::Error.new("paperless error: #{e.response&.dig(:status)}", code: :bad_response)
    end

    def parse_json(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Paperless::Error.new("paperless returned invalid JSON", code: :bad_response)
    end
end
