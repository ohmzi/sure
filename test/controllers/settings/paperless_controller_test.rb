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
    # Ruling M9 (M1), 2026-10-10 close-out: the configured? guard runs first, so
    # the check tests stub it explicitly.
    Paperless::Client.any_instance.stubs(:configured?).returns(true)
    Paperless::Client.any_instance.stubs(:tag_id).returns(1)
    post check_settings_paperless_path
    assert_redirected_to settings_paperless_path
    assert_nil Setting["paperless_token_invalid_at"]
  end

  test "check leaves a stale flag untouched on a non-401 failure" do
    # Ruling M9 (M1), 2026-10-10 close-out: the committed non-401 branch — an
    # unreachable paperless neither clears nor re-stamps the rotation flag.
    stamp = 1.hour.ago.iso8601
    Setting["paperless_token_invalid_at"] = stamp
    Paperless::Client.any_instance.stubs(:configured?).returns(true)
    Paperless::Client.any_instance.stubs(:tag_id).raises(Paperless::Error.new("unreachable", code: :unreachable))
    post check_settings_paperless_path
    assert_redirected_to settings_paperless_path
    assert_equal stamp, Setting["paperless_token_invalid_at"]
  ensure
    Setting["paperless_token_invalid_at"] = nil
  end

  test "check refuses without a configured client and does not flag the token" do
    # Ruling M9 (M1), 2026-10-10 close-out: the configured? guard.
    Paperless::Client.any_instance.stubs(:configured?).returns(false)
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
