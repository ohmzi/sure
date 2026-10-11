require "test_helper"
require_relative "../../support/paperless_test_helper"

class Paperless::ClientTest < ActiveSupport::TestCase
  include PaperlessTestHelper

  test "configured? is false without a token" do
    with_paperless(token: nil) { assert_not Paperless::Client.new.configured? }
  end

  test "configured? is true with a url and token" do
    with_paperless { assert Paperless::Client.new.configured? }
  end

  test "configured? is true with ONLY the token file set (R1)" do
    file = Tempfile.new("paperless-token")
    file.write("file-token-abc123")
    file.close
    with_paperless(token: nil, token_file: file.path) do
      assert Paperless::Client.new.configured?
    end
  ensure
    file&.unlink
  end

  test "the token file is sent as the Authorization header (R1)" do
    file = Tempfile.new("paperless-token")
    file.write("file-token-abc123")
    file.close
    with_paperless(token: nil, token_file: file.path) do
      stub_request(:get, "http://paperless.test:8000/api/tags/")
        .with(query: { "name" => "x" },
              headers: { "Authorization" => "Token file-token-abc123" })
        .to_return(status: 200, body: '{"count":0,"results":[]}', headers: { "Content-Type" => "application/json" })
      stub_request(:post, "http://paperless.test:8000/api/tags/")
        .to_return(status: 201, body: '{"id":9}', headers: { "Content-Type" => "application/json" })
      assert_equal 9, Paperless::Client.new.tag_id("x")
    end
  ensure
    file&.unlink
  end

  test "no committed cassette carries a literal token" do
    paths = Dir[Rails.root.join("test/vcr_cassettes/paperless/*.yml")]
    assert paths.any?, "expected committed paperless cassettes"
    paths.each do |path|
      File.read(path).each_line.grep(/Authorization/) do |line|
        assert_includes line, "<PAPERLESS_API_TOKEN>", "unfiltered token in #{path}"
      end
    end
  end

  test "post_document returns the bare task uuid and sends the document field and token header" do
    with_paperless do
      paperless_cassette("post_document") do
        uuid = Paperless::Client.new.post_document(
          io: StringIO.new("%PDF-1.4 stub"), filename: "receipt.pdf",
          content_type: "application/pdf", title: "Receipt",
          created: Date.new(2026, 10, 1), tags: [ 1, 2 ]
        )
        assert_equal "11111111-2222-3333-4444-555555555555", uuid
        assert_requested :post, "http://paperless.test:8000/api/documents/post_document/",
                         headers: { "Authorization" => "Token test-token" }, times: 1
        # The multipart file field is named `document` (spec §15.1).
        # Ruling 2: WebMock 3.25 raises on ANY body matcher against a
        # multipart/form-data request, so the block form is used — it bypasses
        # the restricted matcher while asserting the same thing.
        # Ruling 3: tags must go out as repeated flat `tags` parts (paperless's
        # QueryDict reads the exact key), never as faraday-multipart's `tags[]`.
        assert_requested(:post, "http://paperless.test:8000/api/documents/post_document/",
                         times: 1) { |request|
          request.body.include?('name="document"') &&
            request.body.scan('name="tags"').size == 2 &&
            !request.body.include?('name="tags[]"')
        }
      end
    end
  end

  test "task maps a success task to its document id" do
    with_paperless do
      paperless_cassette("task_success") do
        task = Paperless::Client.new.task("11111111-2222-3333-4444-555555555555")
        assert_equal :success, task.status
        assert_equal 4242, task.document_id
        assert_nil task.duplicate_of
      end
    end
  end

  test "task raises task_failed for a failed task" do
    with_paperless do
      paperless_cassette("task_failure") do
        error = assert_raises(Paperless::Error) { Paperless::Client.new.task("dead-task") }
        assert_equal :task_failed, error.code
        assert_match(/scanned page missing/, error.message)
      end
    end
  end

  test "document returns the tag PKs and the OCR content" do
    with_paperless do
      paperless_cassette("document") do
        doc = Paperless::Client.new.document(4242)
        assert_equal 4242, doc.id
        assert_equal "Coffee receipt", doc.title
        assert_equal [ 1, 2 ], doc.tag_ids
        assert_equal "Coffee receipt body", doc.content
      end
    end
  end

  test "file streams the paperless bytes and forwards the range response headers" do
    with_paperless do
      paperless_cassette("file_preview") do
        chunks = +""
        status = nil
        headers = nil
        Paperless::Client.new.file(4242, kind: :preview, range: "bytes=0-3") do |chunk, env|
          status ||= env.status
          headers ||= env.response_headers
          chunks << chunk
        end
        assert_equal 206, status
        assert_equal "bytes 0-3/8", headers["content-range"]
        assert_equal "%PDF", chunks
      end
    end
  end

  test "file with no block returns a buffered response whose body is a String" do
    with_paperless do
      paperless_cassette("file_buffered") do
        response = Paperless::Client.new.file(4242, kind: :preview)
        assert_equal 200, response.status
        assert_kind_of String, response.body
        assert_equal "%PDF", response.body
      end
    end
  end

  test "file maps :original to the download path" do
    with_paperless do
      paperless_cassette("file_download") do
        response = Paperless::Client.new.file(4242, kind: :original)
        assert_equal "%PDF", response.body
        assert_requested :get, "http://paperless.test:8000/api/documents/4242/download/", times: 1
      end
    end
  end

  test "a streaming 401 raises unauthorized before any chunk" do
    with_paperless do
      stub_request(:get, "http://paperless.test:8000/api/documents/4242/preview/")
        .to_return(status: 401, body: '{"detail":"Authentication credentials were not provided."}')
      error = assert_raises(Paperless::Error) do
        Paperless::Client.new.file(4242, kind: :preview) { |_chunk, _env| flunk "should not stream" }
      end
      assert_equal :unauthorized, error.code
    end
  end

  # Ruling M5 (M1), 2026-10-10 close-out: pin the streaming branch's honest
  # mid-stream behaviour. Faraday's net_http adapter wraps a mid-body failure
  # (EOFError/Errno::ECONNRESET etc.) in Faraday::ConnectionFailed and raises it
  # from inside the on_data iteration — i.e. AFTER any earlier chunk was already
  # handed to the caller's block. The chunk is delivered, then the pinned
  # :unreachable code surfaces; the caller can no longer send a clean error.
  test "a mid-stream failure raises unreachable after the delivered chunks" do
    request = OpenStruct.new(headers: {}, options: OpenStruct.new)
    connection = Object.new
    connection.define_singleton_method(:get) do |_path, &setup|
      setup.call(request)
      request.options.on_data.call("%PDF", 4, OpenStruct.new(status: 206, response_headers: {}))
      raise Faraday::ConnectionFailed, "mid-body connection reset"
    end
    Paperless::Client.any_instance.stubs(:stream_connection).returns(connection)

    chunks = []
    error = assert_raises(Paperless::Error) do
      Paperless::Client.new.file(4242, kind: :preview) { |chunk, _env| chunks << chunk }
    end
    assert_equal [ "%PDF" ], chunks,
                 "the first chunk is already delivered when the mid-stream failure surfaces"
    assert_equal :unreachable, error.code
  end

  test "a 401 raises unauthorized" do
    with_paperless do
      paperless_cassette("unauthorized") do
        error = assert_raises(Paperless::Error) { Paperless::Client.new.task("x") }
        assert_equal :unauthorized, error.code
        assert_no_match(/test-token/, error.message)
      end
    end
  end

  test "an unreachable host raises unreachable" do
    with_paperless do
      stub_request(:get, "http://paperless.test:8000/api/tasks/")
        .with(query: hash_including("task_id" => "x"))
        .to_raise(Faraday::ConnectionFailed.new("connection refused"))
      error = assert_raises(Paperless::Error) { Paperless::Client.new.task("x") }
      assert_equal :unreachable, error.code
    end
  end

  test "tag_id returns an existing tag's id" do
    with_paperless do
      paperless_cassette("tag_existing") do
        assert_equal 7, Paperless::Client.new.tag_id("ohmzbudget")
        assert_not_requested :post, "http://paperless.test:8000/api/tags/"
      end
    end
  end

  test "tag_id creates a missing tag and returns its id" do
    with_paperless do
      paperless_cassette("tag_create") do
        assert_equal 8, Paperless::Client.new.tag_id("receipt")
      end
    end
  end
end
