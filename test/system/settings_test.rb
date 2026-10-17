require "application_system_test_case"

class SettingsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    # Base settings available to all users
    # Accounts left Settings for its own tab (2026-10-17); Profile is the
    # card at the top of the list.
    @settings_links = []

    @settings_links << [ "Bank sync", settings_providers_path ] if @user.admin?

    @settings_links += [
      [ "Preferences", settings_preferences_path ],
      [ "Profile Info", settings_profile_path ],
      [ "Security", settings_security_path ],
      [ "Categories", categories_path ],
      [ "Tags", tags_path ],
      [ "Rules", rules_path ],
      [ "Merchants", family_merchants_path ],
      [ "Guides", settings_guides_path ],
      [ "What's new", changelog_path ],
      [ "Feedback", feedback_path ]
    ]

    # (Milestone B, design D1) "Statement Vault" is no longer a settings entry
    # — the vault merges into the one Documents entry — so the sequential loop
    # below never meets it. Its retirement is pinned by its own test.
    if @user.admin?
      @settings_links += [
        [ "AI Prompts", settings_ai_prompts_path ],
        [ "API Keys", settings_api_keys_path ]
      ]
    end
  end

  test "can access settings from sidebar" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      open_settings_from_sidebar
      assert_selector "h1", text: "Settings"
      assert_current_path settings_root_path

      @settings_links.each do |name, path|
        find("#settings-nav-container a[href='#{path}']").click
        assert_selector "main h1", text: name
        assert_current_path path
      end
    end
  end

  test "the settings sidebar carries the one Documents entry, not a Statements one" do
    # (Milestone B, design D1) Statements stop being a settings destination of
    # their own; the Documents entry stands in their place, and the vault is
    # reached from the account tab's "Open inbox".
    open_settings_from_sidebar
    assert_no_selector "a[href='#{account_statements_path}']"
    assert_selector "a[href='#{documents_path}']"
  end

  test "can update self hosting settings" do
    sign_in users(:sure_support_staff)
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:anthropic).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:rentcast).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:realie).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:chimnie).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(stub(fetch_latest_release_notes: nil, fetch_release_notes: nil))
    open_settings_from_sidebar
    assert_selector "li", text: "Self-Hosting"
    click_link "Self-Hosting", match: :first
    assert_current_path settings_hosting_path
    assert_selector "h1", text: "Self-Hosting"
    find("select#setting_onboarding_state").select("Invite-only")
    within("select#setting_onboarding_state") do
      assert_selector "option[selected]", text: "Invite-only"
    end
    click_button "Generate new code"
    assert_selector 'span[data-clipboard-target="source"]', visible: true, count: 1 # invite code copy widget
    copy_button = find('button[data-action="clipboard#copy"]', match: :first) # Find the first copy button (adjust if needed)
    page.execute_script("Object.defineProperty(navigator, 'clipboard', { value: { writeText: () => Promise.resolve() }, writable: true, configurable: true })") # Mock clipboard API due to browser security restrictions in tests
    copy_button.click
    assert_selector 'span[data-clipboard-target="iconSuccess"]', visible: true, count: 1 # text copied and icon changed to checkmark
  end

  test "does not show payment link if self hosting" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    open_settings_from_sidebar
    assert_no_selector "li", text: I18n.t("settings.settings_nav.payment_label")
  end

  # Escape is also the settings nav's hotkey back to the page before settings.
  test "Escape closes an open dialog instead of leaving settings" do
    visit settings_api_keys_path
    click_on I18n.t("settings.api_keys.index.revoke_key"), match: :first
    assert_selector "dialog#confirm-dialog[open]"

    page.send_keys(:escape)

    assert_no_selector "dialog#confirm-dialog[open]"
    assert_current_path settings_api_keys_path
  end

  test "does not show admin settings to non-admin users" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      # Visit accounts path directly as non-admin user to avoid user menu issues
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in "Email", with: users(:family_member).email
        fill_in "Password", with: user_password_test
        click_on "Log in"
      end

      # Wait for the login's Turbo redirect before the next visit: without this
      # wait the pending navigation can override it and land on "/" (observed
      # ~1-in-6 flake once this task's member-parity assertion surfaced the
      # wrong page; the pre-existing refutes could not see it). The same
      # waiting intent as application_system_test_case#sign_in.
      assert_current_path root_path

      # Go directly to accounts (settings) page
      visit accounts_path

      # Assert that admin-only settings are not present in the navigation
      assert_no_selector "li", text: "AI Prompts"
      assert_no_selector "li", text: "API Keys"
      assert_no_selector "li", text: "Bank sync"
      # (Milestone B, design D1) statements are no longer a settings entry of
      # their own — one Documents entry — so the vault label is gone and the
      # Documents entry stands in its place.
      assert_no_selector "li", text: "Statement Vault"
      assert_selector "li", text: "Documents"
    end
  end

  private

    def open_settings_from_sidebar
      user_menu = find("div[data-testid=user-menu]", match: :first, visible: :visible)
      within user_menu do
        find("[data-DS--popover-target='button']", match: :first).click
        click_link "Settings", match: :first
      end
    end
end
