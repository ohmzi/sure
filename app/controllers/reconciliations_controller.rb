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
    # cron job decided.
    @results = @links.index_with { |link| ReceiptMatcher.call(link) }
  rescue Paperless::Error
    # Paperless is unreachable: render the persisted rows rather than 500ing the
    # whole inbox. The _result partial tolerates a nil result.
    # (Ruling P-m3-1, 2026-10-10 pre-flight)
    @results = @links.index_with { nil }
    flash.now[:alert] = t(".paperless_unavailable")
  end

  def link
    result = ReceiptMatcher.call(@link)
    entry = choose_entry(result, params[:entry_id])
    return redirect_to reconciliations_path, alert: t(".no_candidate") if entry.nil?

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
    @link.dismiss!
    respond_to do |format|
      format.html { redirect_to reconciliations_path, notice: t(".success") }
      format.turbo_stream { stream_redirect_to reconciliations_path, notice: t(".success") }
    end
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
end
