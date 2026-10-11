# frozen_string_literal: true

# The document bridge's HTTP surface. Every byte of a file goes through #file —
# the browser never talks to paperless (spec §8.4). Ids are resolved through the
# link table; an arbitrary URL is never echoed.
class DocumentLinksController < ApplicationController
  include ActionController::Live

  FILE_KINDS = { "original" => :original, "preview" => :preview, "thumb" => :thumb }.freeze
  # The filename guard moved into DocumentLink::Intake (M7 — the archive form and
  # the wizard share one intake path); this alias keeps M1's constant name
  # resolving for any caller.
  MAX_FILENAME_LENGTH = DocumentLink::Intake::MAX_FILENAME_LENGTH
  # Ruling M6 (M1), 2026-10-10 close-out: title (500) and content_type (100) are
  # column-limited the same way; a longer value would abort inside stage!'s
  # guarded UPDATE after the bytes were already written. Both checks stay in this
  # controller: the archive form is the only caller that accepts a title, and
  # Intake's pinned interface carries neither.
  MAX_TITLE_LENGTH = 500
  MAX_CONTENT_TYPE_LENGTH = 100

  before_action :set_link, only: %i[file link unlink retry destroy]
  before_action :require_document_copy!, only: %i[link unlink]
  before_action :require_non_guest!, only: %i[create link unlink retry destroy]
  rescue_from ActionController::ParameterMissing, with: :bad_request

  def index
    @documents = Current.family.document_links.ordered
    @token_invalid_at = Paperless.token_invalid_at
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("documents.index.title"), documents_path ] ]
    # Ruling 4: explicit view path — implicit render under this controller would
    # resolve to document_links/index, but spec §6 and Task 8 pin the views at
    # app/views/documents/.
    render "documents/index", layout: "settings"
  end

  def create
    file = params.require(:document)
    # Ruling M6 (M1), 2026-10-10 close-out: params.require proves presence only —
    # a hand-rolled POST can send a plain string, which has no #tempfile /
    # #original_filename, so the param's shape is checked before anything reads it.
    return render(plain: "invalid document", status: :bad_request) unless file.respond_to?(:tempfile) && file.respond_to?(:original_filename)
    # Ruling M6 (M1), 2026-10-10 close-out: the column-limited params are checked
    # up front (title 500, content_type 100 — filename 255 and the size cap live
    # in DocumentLink::Intake, which runs before anything is written) — none may
    # reach stage!'s UPDATE, and none may leave a row or bytes behind.
    return render(plain: "title too long", status: :unprocessable_entity) if params[:title].to_s.length > MAX_TITLE_LENGTH
    return render(plain: "content type too long", status: :unprocessable_entity) if file.content_type.to_s.length > MAX_CONTENT_TYPE_LENGTH

    # Pure extraction (M7 Task 3): source resolution, the filename/size caps, the
    # digest-first dedup, savepoint staging and the upload enqueue now live in
    # DocumentLink::Intake, shared with the wizard. This action only maps the
    # PORO's errors onto M1's statuses and bodies.
    link = DocumentLink::Intake.call(family: Current.family, uploader: Current.user,
                                     file: file, source: params[:source].presence, title: params[:title].presence)
    # Ruling 11 (M1): Intake holds the row back to `queued` (with its staged
    # bytes) when the enqueue raises — a `processing` row is in flight.
    if link.status == "queued"
      redirect_to documents_path, alert: t("documents.create.held")
    else
      redirect_to documents_path, notice: t("documents.create.queued")
    end
  rescue DocumentLink::Intake::Duplicate
    # Covers both the digest pre-check and the lost unique-index race in one
    # class. (repaired 2026-10-10, verifier F16) No digest ivar: documents/duplicate
    # never reads @duplicate_digest, so M1's template renders unchanged.
    render "documents/duplicate", status: :conflict
  rescue DocumentLink::Intake::InvalidSource
    render plain: "invalid source", status: :unprocessable_entity
  rescue DocumentLink::Intake::FilenameTooLong
    render plain: "filename too long", status: :unprocessable_entity
  rescue DocumentLink::Staging::TooLargeError
    render plain: "file too large", status: :payload_too_large
  end

  # Streams paperless bytes with Range/Content-Range passthrough. We forward the
  # client's Range header and copy back the upstream status and headers on the
  # first chunk (before the response is committed).
  def file
    return render(plain: "not ready", status: :not_found) if @link.paperless_document_id.blank?

    kind = FILE_KINDS[params[:kind].presence || "preview"]
    return render(plain: "invalid kind", status: :bad_request) unless kind

    started = false
    Paperless.client.file(@link.paperless_document_id, kind: kind, range: request.headers["Range"]) do |chunk, env|
      unless started
        started = true
        response.status = env.status
        %w[content-type content-range content-length accept-ranges].each do |header|
          value = env.response_headers[header]
          response.headers[header.split("-").map(&:capitalize).join("-")] = value if value
        end
        response.headers["Content-Disposition"] = "inline"
      end
      response.stream.write(chunk)
    end
  rescue Paperless::Error => e
    if e.code == :unauthorized
      Paperless.note_token_invalid!
      render plain: "paperless token needs rotation", status: :bad_gateway unless started
    else
      render plain: "paperless unreachable", status: :bad_gateway unless started
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # The viewer navigated away; nothing to render.
  ensure
    response.stream.close
  end

  def link
    entry = Current.family.entries.find(params.require(:entry_id))
    linked = @link.link_to_entry!(entry, confidence: params[:confidence].presence&.to_i)
    return render(plain: "document cannot be linked from its current state", status: :conflict) unless linked

    redirect_to transaction_path(entry), notice: t("documents.link.linked")
  end

  def unlink
    @link.unlink!
    redirect_back_or_to documents_path, notice: t("documents.link.unlinked")
  end

  def retry
    # Ruling M4 (M1), 2026-10-10 close-out: refuse to re-enqueue a row whose
    # upload is already in flight — a processing row, or a row that still holds
    # its paperless task id. Together with UploadJob's task-id guard, a
    # double-submitted retry cannot post the same bytes twice.
    unless @link.status.in?(%w[failed queued]) && @link.paperless_task_id.blank? &&
           @link.staged_path.present? && DocumentLink::Staging.exists?(@link.staged_path)
      return render(plain: "no held upload to retry", status: :conflict)
    end
    @link.retry_upload!
    Paperless::UploadJob.perform_later(@link.id)
    redirect_back_or_to documents_path, notice: t("documents.retry.queued")
  end

  def destroy
    @link.delete_staged!
    @link.destroy!
    redirect_back_or_to documents_path, notice: t("documents.destroy.removed")
  end

  private

    def set_link
      @link = Current.family.document_links.find(params[:id])
    end

    def require_document_copy!
      return if @link.paperless_document_id.present?
      render plain: "no paperless copy yet", status: :conflict
    end

    def bad_request
      render plain: "bad request", status: :bad_request
    end
end
