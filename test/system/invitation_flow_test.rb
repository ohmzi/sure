require "application_system_test_case"

# End-to-end proof that the self-hosted invitation handoff works: an admin
# invites a new address, the invitee's accept page renders the real invitation
# copy and the create-account link. Assertions are pinned to the markup in
# app/views/invitations/{new,accept_choice}.html.erb — the accept page sets
# header_title, which no layout renders, so we assert the rendered message and
# link, not the title.
class InvitationFlowTest < ApplicationSystemTestCase
  test "admin invites a household member and the accept link works" do
    sign_in users(:family_admin)

    visit settings_household_path
    click_on I18n.t("settings.households.show.invite_member") # "Add someone"

    fill_in I18n.t("invitations.new.email_label"), with: "new-member@example.com"
    # The role control is a native <select id="invitation_role">. The view passes
    # `label: t(".role_label")` in the html_options slot, so no <label> element is
    # associated with it (the key renders as a bare `label="Role"` attribute);
    # address the select by its rendered id, not by label text.
    select I18n.t("invitations.new.role_member"), from: "invitation_role"
    click_on I18n.t("invitations.new.submit") # "Send Invitation"

    # Synchronize on the rendered flash before reading the database: the raw
    # query below is not a Capybara command, so without this wait it can run
    # while the form POST is still in flight (observed: the newest row was
    # still a fixture).
    assert_text I18n.t("invitations.create.success") # "Invitation sent successfully"

    invitation = Invitation.order(:created_at).last
    assert_equal "new-member@example.com", invitation.email
    assert_equal "member", invitation.role
    assert invitation.pending?

    visit accept_invitation_path(invitation.token)
    assert_text I18n.t("invitations.accept_choice.message",
                       inviter: invitation.inviter.display_name,
                       role: I18n.t("invitations.new.role_member"))
    assert_link I18n.t("invitations.accept_choice.create_account"),
                href: new_registration_path(invitation: invitation.token)
  end
end
