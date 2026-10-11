# frozen_string_literal: true

class Settings::PaperlessController < ApplicationController
  layout "settings"

  before_action :require_admin!, only: %i[show check]

  def show
    @configured = Paperless.client.configured?
    @token_invalid_at = Paperless.token_invalid_at
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("settings.paperless.show.title"), nil ] ]
  end

  def check
    # Ruling M9 (M1), 2026-10-10 close-out: with no URL/token there is nothing
    # to check — the round trip would 401 and falsely flag a token rotation.
    unless Paperless.client.configured?
      return redirect_to settings_paperless_path, alert: t("settings.paperless.check.unconfigured")
    end
    Paperless.tag_id("ohmzbudget") # a cheap authenticated round trip
    Paperless.clear_token_invalid!
    redirect_to settings_paperless_path, notice: t("settings.paperless.check.ok")
  rescue Paperless::Error => e
    Paperless.note_token_invalid! if e.code == :unauthorized
    redirect_to settings_paperless_path, alert: t("settings.paperless.check.failed")
  end
end
