require "test_helper"

# Contract test against the pinned paperless-ngx container (spec §11). Skips
# when PAPERLESS_CONTRACT_URL is unset, so the suite stays green without one.
class Paperless::ContractTest < ActiveSupport::TestCase
  def setup
    skip "set PAPERLESS_CONTRACT_URL to run the paperless contract test" if ENV["PAPERLESS_CONTRACT_URL"].blank?
  end

  test "the live container answers the client contract" do
    client = Paperless::Client.new(base_url: ENV["PAPERLESS_CONTRACT_URL"])
    assert client.configured?
    assert_kind_of Integer, client.tag_id("ohmzbudget")
    assert_raises(Paperless::Error) { client.task("00000000-0000-0000-0000-000000000000") }
  end
end
