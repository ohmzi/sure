require "test_helper"

# Contract test against the pinned paperless-ngx container (spec §11). Skips
# when PAPERLESS_CONTRACT_URL is unset, so the suite stays green without one.
class Paperless::ContractTest < ActiveSupport::TestCase
  def setup
    skip "set PAPERLESS_CONTRACT_URL to run the paperless contract test" if ENV["PAPERLESS_CONTRACT_URL"].blank?
  end

  test "the live container answers the client contract" do
    # Ruling 13 (M1): this is the ONE test that must talk to a real paperless.
    # Without turned_off the suite-wide VCR config intercepts the request
    # (unhandled-http error) and the test could only ever SKIP, never pass -
    # so spec 12's "contract tests green" was unreachable by construction.
    # Ruling 13 (M1): the suite disables real connections TWICE (VCR with no
    # cassette, and WebMock.disable_net_connect!) - both gates must open for the
    # one test whose whole point is talking to a live paperless.
    WebMock.allow_net_connect!
    VCR.turned_off do
      client = Paperless::Client.new(base_url: ENV["PAPERLESS_CONTRACT_URL"])
      assert client.configured?
      assert_kind_of Integer, client.tag_id("ohmzbudget")
      assert_raises(Paperless::Error) { client.task("00000000-0000-0000-0000-000000000000") }
      # Ruling 12 (M1): the read endpoints, exercised cheaply - a nonexistent id
      # must surface the pinned :not_found on both #document and #file. The happy
      # path needs a document in the live container (none is guaranteed here), so
      # those success shapes stay cassette-covered only - recorded narrow coverage.
      assert_equal :not_found, assert_raises(Paperless::Error) { client.document(999_999_999) }.code
      assert_equal :not_found, assert_raises(Paperless::Error) { client.file(999_999_999, kind: :original) }.code
    end
  ensure
    WebMock.disable_net_connect!
  end
end
