module PaperlessTestHelper
  PAPERLESS_TEST_URL = "http://paperless.test:8000".freeze

  # Points the client at a non-localhost host so VCR (which ignores localhost)
  # intercepts it, and drives the R1 resolution order. Set PAPERLESS_RECORD=1 to
  # record against a live paperless.
  # The env vars win when set, so a live recording run can point the client
  # at a real paperless (ClimateControl.modify overrides, it does not fill).
  def with_paperless(url: ENV.fetch("OHMZBUDGET_PAPERLESS_URL", PAPERLESS_TEST_URL),
                     token: ENV.fetch("OHMZBUDGET_PAPERLESS_TOKEN", "test-token"),
                     token_file: ENV["OHMZBUDGET_PAPERLESS_TOKEN_FILE"])
    with_env_overrides(
      "OHMZBUDGET_PAPERLESS_URL" => url,
      "OHMZBUDGET_PAPERLESS_TOKEN" => token,
      "OHMZBUDGET_PAPERLESS_TOKEN_FILE" => token_file
    ) { yield }
  end

  def paperless_cassette(name, &block)
    VCR.use_cassette("paperless/#{name}", record: ENV["PAPERLESS_RECORD"] ? :all : :none, &block)
  end
end
