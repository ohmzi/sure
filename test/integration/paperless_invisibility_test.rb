require "test_helper"

class PaperlessInvisibilityTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  # (Moved to M8, owner decision 2026-10-11: the archive pages and their search are redesigned there, and
  #  this outage-rendering pin travels with them. M7's close-out keeps the regression gate, the
  #  paperless-invisible audit and the wizard's acceptance journey.)

  test "no rendered archive page exposes a paperless URL or token" do
    with_env_overrides("OHMZBUDGET_PAPERLESS_URL" => "http://paperless.test:8000",
                       "OHMZBUDGET_PAPERLESS_TOKEN" => "must-not-leak") do
      get documents_path
      assert_no_match(/paperless\.test|must-not-leak/, response.body)
    end
  end
end
