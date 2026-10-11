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
      get account_statements_path
      assert_no_match(/paperless\.test|must-not-leak/, response.body)
      get documents_path(q: { search: "coffee" })
      assert_no_match(/paperless\.test|must-not-leak/, response.body)
      get viewer_document_path(document_links(:linked_receipt))
      assert_no_match(/paperless\.test|must-not-leak/, response.body)
    end
  end

  # added by M8 (repaired 2026-10-11, verifier F6):
  test "the browser pages and a viewer render with paperless raising" do
    Paperless::Client.any_instance.stubs(:document).raises(Faraday::ConnectionFailed.new("down"))

    get documents_path
    assert_response :success
    get account_statements_path
    assert_response :success
    get viewer_document_path(document_links(:linked_receipt))
    assert_response :success
  end
end
