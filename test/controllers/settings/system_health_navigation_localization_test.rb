require "test_helper"

class Settings::SystemHealthNavigationLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
  end

  test "German system health navigation has a translation without fallback" do
    assert_equal "Systemstatus", I18n.t("settings.settings_nav.system_health_label", locale: :de, fallback: false, raise: true)
  end

  # One Settings list since the iOS redesign (2026-10-17): the left pane on a
  # computer, the Settings home on a phone.
  test "super admins see the localized system health link in the settings list" do
    user = users(:sure_support_staff)
    sign_in user

    { "de" => "Systemstatus", "en" => "System health" }.each do |locale, label|
      user.update!(locale: locale)
      get settings_preferences_url

      assert_response :success
      assert_select "nav a[href='#{admin_system_health_path}']", text: label, count: 1
    end
  end

  test "German system health navigation remains hidden from other roles" do
    %i[family_admin family_member].each do |fixture|
      user = users(fixture)
      user.update!(locale: "de")
      sign_in user
      get settings_preferences_url

      assert_response :success
      assert_select "nav a[href='#{admin_system_health_path}']", count: 0
    end
  end
end
