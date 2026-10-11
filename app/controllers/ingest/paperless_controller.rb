# frozen_string_literal: true

# The paperless workflow webhook (spec §8.5). API-key authed by a single
# least-privilege integration user; the payload is untrusted and validated
# strictly, and NOTHING but document_links rows keyed by a paperless document
# id is ever touched. Polling remains the guaranteed path — this is best effort.
class Ingest::PaperlessController < ApplicationController
  INTEGRATION_EMAIL = "paperless-ingest@ohmzbudget.invalid".freeze
  ALLOWED_STATUSES = %w[consumed failed].freeze

  # Skip session auth and CSRF (this is a token-authed machine route) but keep
  # the host/origin guards — the token never bypasses them (§5, §15.5).
  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade

  before_action :authenticate_ingest_key!

  def create
    document_id = parse_document_id
    return render(json: { error: "invalid documentId" }, status: :bad_request) if document_id.nil?

    status = params[:status].presence
    return render(json: { error: "invalid status" }, status: :bad_request) if status && !ALLOWED_STATUSES.include?(status)

    # Ruling M8 (M1), 2026-10-10 close-out: scoped through the integration
    # user's family — the webhook can only ever settle its own household's rows.
    link = @ingest_user.family.document_links.find_by(paperless_document_id: document_id)
    return head :ok unless link # unknown id: idempotent no-op

    if status.nil? || status == "consumed"
      link.finish_processing!(document_id: document_id) # guarded: only a processing row
    else
      link.fail!("paperless reported the document failed") # guarded: only a processing row
    end
    head :ok
  end

  private

    def authenticate_ingest_key!
      key_value = request.headers["X-Api-Key"]
      # Ruling 5 (M1): `present? && find_by_value(...)` yields literal `false`
      # when the header is absent, and `false&.active?` raises NoMethodError
      # (the safe-nav operator guards nil only). The trailing `if` yields nil.
      api_key = ApiKey.find_by_value(key_value) if key_value.present?
      return render(json: { error: "unauthorized" }, status: :unauthorized) unless api_key&.active?
      # Ruling M8 (M1), 2026-10-10 close-out: a key can be active while its user
      # is deactivated (deactivation revokes keys transactionally, but the gate
      # reads the live user row). The scoping family is the integration user's.
      @ingest_user = api_key.user
      return render(json: { error: "unauthorized" }, status: :unauthorized) unless @ingest_user&.active?
      return render(json: { error: "forbidden" }, status: :forbidden) unless api_key.scopes.include?("read_write")
      # Ruling 5 (M1): no `return` on the last statement — rubocop's
      # Style/RedundantReturn is a plan-mandated gate; control flow is identical.
      render(json: { error: "forbidden" }, status: :forbidden) unless @ingest_user.email == INTEGRATION_EMAIL
    end

    def parse_document_id
      raw = params[:documentId]
      return nil unless raw.is_a?(Integer) || raw.to_s.match?(/\A\d+\z/)
      id = raw.to_i
      # Ruling M8 (M1), 2026-10-10 close-out: paperless_document_id is a bigint —
      # an out-of-range id would raise PG::NumericValueOutOfRange in the lookup,
      # so it is malformed input, not a lookup.
      id.between?(1, (2**63) - 1) ? id : nil
    end
end
