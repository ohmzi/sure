class ReconciliationsController < ApplicationController
  include StreamExtensions

  before_action :require_non_guest!
  before_action :set_reconciliation, only: %i[link dismiss]

  def index
    scope = DocumentLink
              .where(family_id: Current.family.id, status: %w[suggested pending_review])
              .order(updated_at: :desc)

    @pagy, @links = pagy(scope, limit: safe_per_page)
    # Candidate rows are recomputed on render rather than cached: the matcher is
    # deterministic over the same OCR text, so the inbox shows exactly what the
    # cron job decided. (Ruling M3-C2, 2026-10-11 close-out) The recompute is
    # viewer-scoped (Account.accessible_by — the accounts/transactions model):
    # a candidate row is only ever an entry on an account the current user can
    # see, so an unshared account's name/amount/date never renders.
    @results = @links.index_with { |link| ReceiptMatcher.call(link, viewer: Current.user) }
  rescue Paperless::Error
    # Paperless is unreachable: render the persisted rows rather than 500ing the
    # whole inbox. The _result partial tolerates a nil result.
    # (Ruling P-m3-1, 2026-10-10 pre-flight)
    @results = @links.index_with { nil }
    flash.now[:alert] = t(".paperless_unavailable")
  end

  def link
    result = ReceiptMatcher.call(@link, viewer: Current.user)
    entry = choose_entry(result, params[:entry_id])

    if entry.nil?
      # (Ruling M3-C2 R1c, 2026-10-11 close-out) an entry_id that exists in the
      # family but sits on an account the user cannot see is refused with the
      # app's standard not-authorized path; everything else stays "not a match".
      return refuse_not_authorized! if params[:entry_id].present? && !visible_entry_id?
      return redirect_to reconciliations_path, alert: t(".no_candidate")
    end

    @link.link_to_entry!(entry, confidence: confidence_for(result, entry))
    respond_to do |format|
      format.html { redirect_to reconciliations_path, notice: t(".success") }
      format.turbo_stream { stream_redirect_to reconciliations_path, notice: t(".success") }
    end
  rescue Paperless::Error
    # Paperless is unreachable: nothing can be re-checked, so return to the inbox
    # with an alert. (Ruling P-m3-1, 2026-10-10 pre-flight)
    redirect_to reconciliations_path, alert: t(".paperless_unavailable")
  end

  def dismiss
    result = ReceiptMatcher.call(@link, viewer: Current.user)
    # (Ruling M3-C2 R1c, 2026-10-11 close-out) a receipt whose matches the user
    # cannot see is not theirs to resolve: refuse with the standard
    # not-authorized path. A receipt with no family-wide match left is a stale
    # suggestion (its entry was edited or deleted away), still dismissable.
    return refuse_not_authorized! if result.candidates.empty? && family_wide_match?

    @link.dismiss!
    respond_to do |format|
      format.html { redirect_to reconciliations_path, notice: t(".success") }
      format.turbo_stream { stream_redirect_to reconciliations_path, notice: t(".success") }
    end
  rescue Paperless::Error
    # (Ruling M3-C2 R1c, 2026-10-11 close-out) the visibility check reads the
    # document from paperless; an outage must answer honestly, not 500.
    redirect_to reconciliations_path, alert: t(".paperless_unavailable")
  end

  private
    def set_reconciliation
      @link = DocumentLink.where(family_id: Current.family.id).find(params[:id])
    end

    # Only an entry the matcher actually produced may be linked, so a crafted
    # entry_id cannot attach an arbitrary transaction to a receipt.
    def choose_entry(result, entry_id)
      if entry_id.present?
        result.candidates.map(&:entry).find { |entry| entry.id == entry_id }
      else
        result.best&.entry
      end
    end

    def confidence_for(result, entry)
      result.candidates.find { |candidate| candidate.entry.id == entry.id }&.score
    end

    # (Ruling M3-C2 R1c, 2026-10-11 close-out) the requested entry as the family
    # stores it, to tell a visibility refusal from a plain non-match.
    def visible_entry_id?
      entry = Current.family.entries.find_by(id: params[:entry_id])
      entry.present? && account_visible?(entry.account)
    end

    # The app's account-visibility model: owner or AccountShare
    # (Account.accessible_by). (Ruling M3-C2 R1, 2026-10-11 close-out)
    def account_visible?(account)
      account.present? && Current.family.accounts.accessible_by(Current.user).exists?(id: account.id)
    end

    # The family-wide state the cron job sees (viewer nil), used only to tell a
    # visibility refusal from a stale suggestion; never rendered.
    def family_wide_match?
      ReceiptMatcher.call(@link, viewer: nil).candidates.any?
    end

    # The app's standard not-authorized refusal
    # (AccountAuthorizable#require_account_permission!'s response shape).
    # (Ruling M3-C2 R1c, 2026-10-11 close-out)
    def refuse_not_authorized!
      respond_to do |format|
        format.html { redirect_back_or_to reconciliations_path, alert: t("accounts.not_authorized") }
        format.turbo_stream { stream_redirect_back_or_to reconciliations_path, alert: t("accounts.not_authorized") }
        format.json { render json: { error: t("accounts.not_authorized") }, status: :forbidden }
      end
    end
end
