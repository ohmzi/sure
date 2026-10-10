require "test_helper"

class Settings::PaperlessControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "shows the configured state" do
    with_env_overrides("OHMZBUDGET_PAPERLESS_URL" => "http://paperless.test:8000", "OHMZBUDGET_PAPERLESS_TOKEN" => "x") do
      get settings_paperless_path
    end
    assert_response :success
    assert_match I18n.t("settings.paperless.show.configured"), response.body
  end

  test "shows the rotation warning when the token was rejected" do
    Setting["paperless_token_invalid_at"] = 1.hour.ago.iso8601
    get settings_paperless_path
    assert_match I18n.t("settings.paperless.show.rotation_title"), response.body
  ensure
    Setting["paperless_token_invalid_at"] = nil
  end

  test "check clears the flag when paperless answers" do
    Setting["paperless_token_invalid_at"] = 1.hour.ago.iso8601
    Paperless::Client.any_instance.stubs(:tag_id).returns(1)
    post check_settings_paperless_path
    assert_redirected_to settings_paperless_path
    assert_nil Setting["paperless_token_invalid_at"]
  end

  test "check refuses non-admins" do
    sign_in users(:family_member)
    post check_settings_paperless_path
    assert_response :redirect
    assert_redirected_to accounts_path
  end
end
