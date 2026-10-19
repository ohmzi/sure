require "test_helper"

# Settings audit (the owner, 2026-10-19): the household — its name, members
# and invitations — is a page of its own, no longer the middle of Profile.
class Settings::HouseholdsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
  end

  test "the household page lists the members and invites more" do
    sign_in @admin
    get settings_household_path

    assert_response :success
    @admin.family.users.each { |user| assert_select "[data-household-member]", text: /#{Regexp.escape(user.display_name)}/ }
    assert_select "a[href='#{new_invitation_path}']", text: I18n.t("settings.households.show.invite_member")
    assert_select "input[name='user[redirect_to]'][value='household']", visible: :all
  end

  test "profile no longer carries the household" do
    sign_in @admin
    get settings_profile_path

    assert_select "[data-household-member]", count: 0
  end

  test "the settings list leads to the household" do
    sign_in @admin
    get settings_root_path

    assert_select "nav a[href='#{settings_household_path}']"
  end

  test "renaming the household from its page returns to it" do
    sign_in @admin
    patch user_path(@admin), params: { user: { redirect_to: "household", family_attributes: { name: "The Renamed", id: @admin.family.id } } }

    assert_redirected_to settings_household_path
    assert_equal "The Renamed", @admin.family.reload.name
  end
end
