# frozen_string_literal: true

require "digest"

# One file in, one staged + queued DocumentLink out. Extracted from
# DocumentLinksController#create (M1 Rulings 4/6) so the archive form and the
# M7 wizard share exactly one intake path — digest-first dedup, the size cap
# BEFORE the digest read, savepoint staging, and the upload enqueue.
#
# The controller-side guards M1 added and the pinned interface does not carry —
# the param-shape check and the title/content-type column limits — stay with
# their callers: this PORO's contract raises only the four errors below.
class DocumentLink::Intake
  # document_links.original_filename is varchar(255); a longer value would
  # raise PG::StringDataRightTruncation inside stage!'s guarded UPDATE — after
  # the bytes were written.
  MAX_FILENAME_LENGTH = 255

  Duplicate = Class.new(StandardError)
  InvalidSource = Class.new(StandardError)
  FilenameTooLong = Class.new(StandardError)

  class << self
    def call(family:, uploader:, file:, source: nil, title: nil, enqueue: nil)
      new(family: family, uploader: uploader, file: file, source: source, title: title, enqueue: enqueue).call
    end
  end

  def initialize(family:, uploader:, file:, source:, title:, enqueue: nil)
    @family = family
    @uploader = uploader
    @file = file
    @source = source
    @title = title
    @enqueue = enqueue
  end

  def call
    # The reader decides the document's class. A blank source (the archive
    # form's "detect automatically") starts every upload as a receipt; the
    # native read's DocumentClassifier writes the real class once the bytes are
    # read. The old filename heuristic (DocumentLink::SourceGuesser) is gone
    # because it could not tell a photographed receipt from a scanned statement.
    resolved_source = @source.presence || "receipt"
    raise InvalidSource unless DocumentLink::SOURCES.include?(resolved_source)
    raise FilenameTooLong if filename.length > MAX_FILENAME_LENGTH
    # Cap before the digest read: an over-cap upload must never be buffered in
    # memory, create a row that can never progress, or leave a partial file.
    raise DocumentLink::Staging::TooLargeError if @file.tempfile.size > DocumentLink::Staging::MAX_BYTES

    digest = Digest::SHA256.digest(@file.tempfile.read).unpack1("H*")
    @file.tempfile.rewind
    raise Duplicate if @family.document_links.exists?(content_sha256: digest)

    link = DocumentLink.link_from_upload!(family: @family, uploader: @uploader,
                                          source: resolved_source, title: @title.presence)
    begin
      # Savepoint: a failed stage! (a lost unique-index race, a rejected value)
      # aborts the surrounding transaction, which would poison the cleanup below.
      DocumentLink.transaction(requires_new: true) do
        link.stage!(io: @file.tempfile, filename: filename, content_type: content_type)
      end
    rescue StandardError
      # stage! failed after the row existed: reclaim the bytes it wrote and drop
      # the row — a queued row with no stored_path can never progress or retry.
      DocumentLink::Staging.delete(link.id.to_s)
      link.destroy!
      raise
    end
    link.mark_processing!
    enqueue_upload(link)
    # `transition!` writes with `update_all`, so the in-memory row still reads
    # `queued` after mark_processing! (and `processing` after a hold!). The
    # caller's held-vs-in-flight check and the intake contract both need the
    # real row, so hand back a fresh read.
    link.reload
  rescue ActiveRecord::RecordNotUnique
    # The digest check above is check-then-act: two concurrent uploads of the
    # same bytes (a double-click submit) can both pass it, and the loser hits
    # the (family_id, content_sha256) unique index inside stage!. It has been
    # cleaned up; answer it like the duplicate it is, never a 500.
    raise Duplicate
  end

  private
    # Ruling 11 (M1): an enqueue failure must not strand the row in `processing`
    # — no poll would ever pick it up (the poll is scheduled by the job), the
    # webhook cannot match a nil document id, the retry route accepts only
    # failed/queued, and the unfiltered (family, sha256) unique index blocks a
    # re-upload. On a raise (production: Sidekiq/Redis down) hold the row back to
    # `queued` with its staged bytes so the retry route can re-drive it. The
    # caller distinguishes the held outcome from the queued-for-upload one by the
    # returned row's status (`queued` = held, `processing` = in flight).
    #
    # `enqueue:` lets a caller choose the job; the default is the native
    # DocumentUnderstandingJob. The archive's upload route and the wizard now
    # run the same read, so one document is never read by two pipelines.
    def enqueue_upload(link)
      job = @enqueue || ->(l) { DocumentUnderstandingJob.perform_later(l.id) }
      job.call(link)
    rescue => e
      link.hold!(message: "enqueue failed: #{e.class}")
    end

    def filename = @file.original_filename.to_s
    def content_type = @file.content_type
end
