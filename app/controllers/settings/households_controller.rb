# The household — its name, members and invitations — on a page of its own
# (the Settings audit, the owner, 2026-10-19); it used to sit in the middle of
# Profile, between your name and the danger zone.
class Settings::HouseholdsController < ApplicationController
  layout "settings"

  def show
    @users = Current.family.users.order(:created_at)
    @pending_invitations = Current.family.invitations.pending
  end
end
