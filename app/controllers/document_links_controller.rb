# frozen_string_literal: true

# The document bridge's HTTP surface. Every byte of a file goes through #file —
# the browser never talks to paperless (spec §8.4). Ids are resolved through the
# link table; an arbitrary URL is never echoed.
class DocumentLinksController < ApplicationController
  include ActionController::Live

  FILE_KINDS = { "original" => :original, "preview" => :preview, "thumb" => :thumb }.freeze

  before_action :set_link, only: %i[file link unlink retry destroy]
  before_action :require_document_copy!, only: %i[link unlink]
  before_action :require_non_guest!, only: %i[create link unlink retry destroy]
  rescue_from ActionController::ParameterMissing, with: :bad_request

  def index
    @documents = Current.family.document_links.ordered
    @token_invalid_at = Paperless.token_invalid_at
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("documents.index.title"), documents_path ] ]
    render layout: "settings"
  end

  def create
    file = params.require(:document)
    source = params.require(:source).to_s
    return render(plain: "invalid source", status: :unprocessable_entity) unless DocumentLink::SOURCES.include?(source)

    digest = Digest::SHA256.digest(file.tempfile.read).unpack1("H*")
    file.tempfile.rewind
    if Current.family.document_links.exists?(content_sha256: digest)
      @duplicate_digest = digest
      return render :duplicate, status: :conflict
    end

    link = DocumentLink.link_from_upload!(family: Current.family, uploader: Current.user,
                                          source: source, title: params[:title].presence)
    link.stage!(io: file.tempfile, filename: file.original_filename, content_type: file.content_type)
    link.mark_processing!
    Paperless::UploadJob.perform_later(link.id)
    redirect_to documents_path, notice: t("documents.create.queued")
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
    @link.link_to_entry!(entry, confidence: params[:confidence].presence&.to_i)
    redirect_to transaction_path(entry), notice: t("documents.link.linked")
  end

  def unlink
    @link.unlink!
    redirect_back_or_to documents_path, notice: t("documents.link.unlinked")
  end

  def retry
    unless @link.status.in?(%w[failed queued]) &&
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
