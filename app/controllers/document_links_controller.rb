# frozen_string_literal: true

# The document bridge's HTTP surface. Every byte of a file goes through #file,
# served from the document's own stored copy — the browser never talks to any
# external engine (spec §8.4). Ids are resolved through the link table; an
# arbitrary URL is never echoed.
class DocumentLinksController < ApplicationController
  include DocumentBrowser

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

  # The page IS the household's Documents page (Milestone B, design D1): one
  # entry, one list, statements and receipts together by default, the type in an
  # in-page facet (DocumentLink::Search#type_filters). The old top-level `source`
  # pair narrowed it to receipt|bill; the type facet replaces it.
  before_action :set_link, only: %i[file viewer show link unlink retry destroy]
  before_action :require_document_copy!, only: %i[link unlink]
  before_action :require_non_guest!, only: %i[create link unlink retry destroy]
  rescue_from ActionController::ParameterMissing, with: :bad_request

  def index
    @filters = document_browser_filters
    @pagy, @links = pagy(document_browser_search.relation, limit: safe_per_page(20))
    # The viewer URL carries the page's query string (M8 locked decision 3), so
    # the modal's prev/next recompute over the same filtered list.
    @rows = @links.map { |link| DocumentBrowser::Row.for_document_link(link, viewer_url: viewer_document_path(link, document_browser_viewer_params)) }
    # The tag facet's choices come from the stored snapshot (M8 Task 6), never
    # a live external call.
    @tag_choices = DocumentLink.tag_snapshot_names(Current.family.document_links.not_deleted)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("documents.index.title"), documents_path ] ]
    # Ruling 4: explicit view path — implicit render under this controller would
    # resolve to document_links/index, but spec §6 and Task 8 pin the views at
    # app/views/documents/.
    render "documents/index" # main chrome: this page is a first-class destination
  end

  # GET /documents/:id/viewer — the modal. Prev/next recompute over the SAME
  # relation the index listed (M8 locked decision 3), so the walk is correct
  # across pagination and filters.
  def viewer
    # The modal does not link to itself: the row presenter is built without a
    # viewer_url here (that field exists for the index rows).
    @row = DocumentBrowser::Row.for_document_link(@link)
    # The read's view-model (Milestone B Task 4): what the viewer shows beside
    # the document — the fields, their confidences, the checks, and what it
    # became — or, unread, the reason and the two ways forward.
    @panel = DocumentPanel.new(@link)
    previous_link, next_link = document_browser_neighbours(@link)
    @previous_url = previous_link && viewer_document_path(previous_link, document_browser_viewer_params)
    @previous_title = previous_link && link_display_title(previous_link)
    @next_url = next_link && viewer_document_path(next_link, document_browser_viewer_params)
    @next_title = next_link && link_display_title(next_link)
    # Ruling 4 (M8 Task 2, restated): the implicit render under this controller
    # would resolve to document_links/viewer; the view lives at
    # app/views/documents/ with the rest of the page.
    render "documents/viewer"
  end

  # GET /documents/:id — the document on its own page. The modal above is the way
  # in from the grid; this is the stable, shareable URL (`Row#details_url`) for
  # the same document-left / what-was-understood-right content, with no dialog to
  # open and no JavaScript needed.
  def show
    @row = DocumentBrowser::Row.for_document_link(@link)
    @panel = DocumentPanel.new(@link)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("documents.index.title"), documents_path ],
      [ @row.title, nil ]
    ]
    render "documents/show"
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

  # Serves the document's own stored bytes. Range requests are honored with the
  # same 206/Content-Range passthrough the old proxy exposed, so the in-page PDF
  # viewer can seek; the row/viewer Download affordance passes `download: true`
  # so the disposition is an attachment instead of inline.
  def file
    return render(plain: "not ready", status: :not_found) if @link.stored_path.blank?

    kind = FILE_KINDS[params[:kind].presence || "preview"]
    return render(plain: "invalid kind", status: :bad_request) unless kind

    path = DocumentLink::Staging.resolve!(@link.stored_path)
    return render(plain: "not ready", status: :not_found) unless path.file?

    content_type = @link.content_type.presence || "application/octet-stream"
    disposition = ActiveModel::Type::Boolean.new.cast(params[:download]) ? :attachment : :inline
    filename = @link.original_filename.presence || "document"

    size = path.size
    response.headers["Accept-Ranges"] = "bytes"
    if (range = http_range(size))
      first, last = range
      response.headers["Content-Range"] = "bytes #{first}-#{last}/#{size}"
      send_data(path.binread(last - first + 1, first),
                type: content_type, disposition: disposition, filename: filename, status: :partial_content)
    else
      send_data(path.binread, type: content_type, disposition: disposition, filename: filename)
    end
  rescue ArgumentError
    # A stored_path outside the store root (or an unreadable one): serve nothing
    # rather than 500.
    render plain: "not ready", status: :not_found
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
    # Refuse to re-enqueue a row whose read is already in flight, or a row with
    # no held bytes to read.
    unless @link.status.in?(%w[failed queued]) &&
           @link.stored_path.present? && DocumentLink::Staging.exists?(@link.stored_path)
      return render(plain: "no held upload to retry", status: :conflict)
    end
    @link.retry_upload!
    DocumentUnderstandingJob.perform_later(@link.id)
    redirect_back_or_to documents_path, notice: t("documents.retry.queued")
  end

  def destroy
    # Spec N9: money is never silently cascaded. Refuse while anything derived
    # is unreconciled, and NAME what is in the way -- a blocking rule the user
    # cannot act on, or cannot see, is a wall. When it is clear, the bytes go and
    # the row stays as a tombstone, so the entry it produced still tells the
    # truth about where it came from.
    unless @link.deletable?
      return redirect_back_or_to documents_path,
                                alert: t("documents.destroy.blocked", entries: @link.deletion_blockers.to_sentence)
    end

    @link.soft_delete!
    redirect_back_or_to documents_path, notice: t("documents.destroy.removed")
  end

  private

    def document_browser_search
      DocumentLink::Search.new(family: Current.family, filters: document_browser_filters)
    end

    # The walk is recomputed server-side over the same filtered relation the
    # index listed (M8 locked decision 3): pagination can never desync it. A
    # stale URL whose row is not in the relation renders no neighbours.
    def document_browser_neighbours(link)
      ids = document_browser_search.relation.pluck(:id)
      position = ids.index(link.id)
      return [ nil, nil ] unless position

      [
        (Current.family.document_links.find(ids[position - 1]) if position.positive?),
        (Current.family.document_links.find(ids[position + 1]) if ids[position + 1])
      ]
    end

    def link_display_title(link) = link.title.presence || link.original_filename

    def set_link
      # A tombstone has left the archive: the viewer, its bytes and its actions
      # are all gone (404), so a stale URL cannot resurrect a deleted document.
      @link = Current.family.document_links.not_deleted.find(params[:id])
    end

    def require_document_copy!
      return if @link.stored_path.present?
      render plain: "no stored copy yet", status: :conflict
    end

    # "bytes=0-3" -> [0, 3]; "bytes=4-" -> [4, size-1]; "bytes=-5" -> the last
    # five bytes. A malformed or unsatisfiable range is ignored (200, full body).
    def http_range(size)
      match = request.headers["Range"].to_s.match(/\Abytes=(\d*)-(\d*)\z/)
      return nil unless match && (match[1].present? || match[2].present?)

      if match[1].empty?
        length = match[2].to_i
        return nil if length.zero? || size.zero?
        [ [ size - length, 0 ].max, size - 1 ]
      else
        first = match[1].to_i
        last = match[2].present? ? [ match[2].to_i, size - 1 ].min : size - 1
        return nil if first > last || first >= size
        [ first, last ]
      end
    end

    def bad_request
      render plain: "bad request", status: :bad_request
    end
end
