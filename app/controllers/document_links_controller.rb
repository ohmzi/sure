# frozen_string_literal: true

# The document bridge's HTTP surface. Every byte of a file goes through #file —
# the browser never talks to paperless (spec §8.4). Ids are resolved through the
# link table; an arbitrary URL is never echoed.
class DocumentLinksController < ApplicationController
  include ActionController::Live

  FILE_KINDS = { "original" => :original, "preview" => :preview, "thumb" => :thumb }.freeze
  # document_links.original_filename is varchar(255) (db/schema.rb). A longer
  # value would raise PG::StringDataRightTruncation inside stage!'s guarded
  # UPDATE — after the bytes were already written.
  MAX_FILENAME_LENGTH = 255

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
    source = params[:source].presence ||
             DocumentLink::SourceGuesser.guess(filename: file.original_filename, content_type: file.content_type).to_s
    return render(plain: "invalid source", status: :unprocessable_entity) unless DocumentLink::SOURCES.include?(source)
    return render(plain: "filename too long", status: :unprocessable_entity) if file.original_filename.to_s.length > MAX_FILENAME_LENGTH
    # Cap before the digest read: an over-cap upload must never be buffered in
    # memory, create a row that can never progress, or leave a partial file.
    return render(plain: "file too large", status: :payload_too_large) if file.tempfile.size > DocumentLink::Staging::MAX_BYTES

    digest = Digest::SHA256.digest(file.tempfile.read).unpack1("H*")
    file.tempfile.rewind
    if Current.family.document_links.exists?(content_sha256: digest)
      @duplicate_digest = digest
      # Ruling 4: explicit view path (see #index) — spec §6 pins app/views/documents/.
      return render "documents/duplicate", status: :conflict
    end

    link = DocumentLink.link_from_upload!(family: Current.family, uploader: Current.user,
                                          source: source, title: params[:title].presence)
    begin
      # Savepoint: a failed stage! (a lost unique-index race, a rejected value)
      # aborts the surrounding transaction, which would poison the cleanup below.
      DocumentLink.transaction(requires_new: true) do
        link.stage!(io: file.tempfile, filename: file.original_filename, content_type: file.content_type)
      end
    rescue StandardError
      # stage! failed after the row existed: reclaim the bytes it wrote and drop
      # the row — a queued row with no staged_path can never progress or retry.
      DocumentLink::Staging.delete(link.id.to_s)
      link.destroy!
      raise
    end
    link.mark_processing!
    Paperless::UploadJob.perform_later(link.id)
    redirect_to documents_path, notice: t("documents.create.queued")
  rescue DocumentLink::Staging::TooLargeError
    render plain: "file too large", status: :payload_too_large
  rescue ActiveRecord::RecordNotUnique
    # The digest check above is check-then-act: two concurrent uploads of the
    # same bytes (a double-click submit) can both pass it, and the loser hits
    # the (family_id, content_sha256) unique index inside stage!. It has been
    # cleaned up; answer 409 like the duplicate it is, never a 500.
    render plain: "duplicate document", status: :conflict
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
