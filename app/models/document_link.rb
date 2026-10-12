# frozen_string_literal: true

require "digest"

# The receipt/bill/statement spine. One row per uploaded document: it tracks the
# paperless upload, the staged bytes while paperless is unreachable, and the
# optional link to an entry. Status changes go through `transition!` only — a
# single atomic conditional UPDATE, so a late poll or webhook can never clobber
# a row the user already moved on.
class DocumentLink < ApplicationRecord
  STATUSES  = %w[queued processing unlinked suggested pending_review linked verified dismissed failed].freeze
  SOURCES   = %w[receipt bill statement other].freeze
  LINKABLE  = %w[unlinked suggested pending_review linked].freeze
  # Ruling M2 (M1), 2026-10-10 close-out: a `SETTLEABLE` constant was deleted —
  # no task, and no shipped code path, ever consumed it; every `transition!`
  # carries its own inline `from:` list.
  # The only statuses `record_match!` may write (R4). `:no_match` is a deliberate
  # no-write on M3's side, so it is not a writable outcome here.
  MATCHER_OUTCOMES = %w[suggested pending_review].freeze
  # The snapshot size bound (M7 decision 8): long statements are truncated so
  # one OCR body cannot bloat the row or slow the ILIKE scans unboundedly.
  EXTRACTED_TEXT_LIMIT = 100_000

  belongs_to :family
  belongs_to :entry, optional: true
  belongs_to :account_statement, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  # Receipt/bill drafts created by the M7 wizard. Nullified (never destroyed)
  # when a link is removed: the draft's history outlives the bytes.
  has_many :receipt_imports, class_name: "ReceiptImport", foreign_key: :document_link_id, dependent: :nullify

  # Every read of this document's bytes. Destroyed with the row: a read has no
  # meaning without its document.
  has_many :document_extractions, dependent: :destroy

  # The "what I understood" read for the viewer and the review screen.
  def extraction = document_extractions.order(created_at: :desc).first

  enum :source, { receipt: "receipt", bill: "bill", statement: "statement", other: "other" }, validate: true

  validates :status, inclusion: { in: STATUSES }

  scope :for_entry, ->(entry) { where(entry_id: entry.respond_to?(:id) ? entry.id : entry) }
  scope :ordered, -> { order(created_at: :desc) }

  class << self
    # The only way a row enters the system. The caller stages bytes
    # (DocumentLink#stage!, Task 3) and enqueues Paperless::UploadJob.
    def link_from_upload!(family:, uploader:, source:, title: nil)
      create!(family: family, created_by: uploader, source: source, title: title, status: "queued")
    end

    # (Ruling M7-L9, 2026-10-11 close-out) The re-drive for a lost snapshot
    # enqueue: `finish_processing!` rescues the raise and leaves the row
    # settled-but-snapshotless, which is exactly this scope. SyncCleanerJob
    # sweeps it hourly; the paperless:backfill_extracted_text rake task's scope
    # is the wider `capture_pending_snapshot` below (M8 Task 6). Idempotent —
    # CaptureContentJob no-ops when the snapshot already exists, so neither path
    # can overwrite a good snapshot or double-apply. Returns the scanned count,
    # for the task's output.
    def capture_pending_content
      scope = where.not(paperless_document_id: nil).where(extracted_text: nil)
      count = scope.count
      scope.find_each { |link| Paperless::CaptureContentJob.perform_later(link.id) }
      count
    end

    # The operator-driven backfill's scope (M8 locked decision 6): a settled row
    # is re-driven when its OCR snapshot OR its tag snapshot is missing. Kept
    # separate from capture_pending_content on purpose — a genuinely tag-less
    # document can never leave the tag scope (record_tags! refuses blank names),
    # so sweeping tags hourly would re-fetch it from paperless forever; the
    # backfill is the documented refresh path and its re-fetch is bounded to
    # its runs (M8 self-review). Returns the scanned count.
    def capture_pending_snapshot
      scope = where.not(paperless_document_id: nil).where("extracted_text IS NULL OR tags = '{}'")
      count = scope.count
      scope.find_each { |link| Paperless::CaptureContentJob.perform_later(link.id) }
      count
    end

    # Local OCR-context search (M8 locked decision 4 / M7 Task 10's pin): the
    # snapshot, the title and the filename — never paperless. sanitize_sql_like
    # keeps a typed % or _ literal (the EntrySearch idiom).
    def search(query)
      term = query.to_s.strip
      return all if term.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      where("extracted_text ILIKE :p OR title ILIKE :p OR original_filename ILIKE :p", p: pattern)
    end

    # The tag facet's vocabulary (M8 Task 6): the distinct names stored in the
    # snapshot, so the choices render and filter with paperless down (locked
    # decision 4). Callers pass the scope whose tags they may show.
    def tag_snapshot_names(scope = all)
      scope.distinct.pluck(Arel.sql("unnest(tags)")).compact.sort
    end

    # The sidebar's ready-to-review count (M8 Task 9, Ruling M8-L1 decision 3):
    # the family's documents whose receipt draft has settled into `understood`
    # and has NOT been published (`complete`) — the draft state the row's
    # "Review details" affordance reads, so a reviewed-and-published receipt
    # stops counting instead of inflating the badge forever. A link carries one
    # draft by construction. Local, like every other archive read.
    def pending_review_count_for(family)
      ready = ReceiptImport.where(understanding_state: "understood")
                           .where.not(status: "complete")
                           .select(:document_link_id)
      where(family: family).where(id: ready).count
    end
  end

  # The single write path for status changes. Moves the row only while it is
  # still in `from`; returns true when exactly one row moved. This is the
  # M2 ruling re-encoded: guarded, atomic, one writer.
  def transition!(from:, to:, **attributes)
    self.class.where(id: id, status: Array(from))
        .update_all(attributes.merge(status: to, updated_at: Time.current)) == 1
  end

  def mark_processing!(paperless_document_id: nil)
    attrs = {}
    attrs[:paperless_document_id] = paperless_document_id if paperless_document_id
    transition!(from: %w[queued failed processing], to: "processing", **attrs)
  end

  def record_task!(task_id)
    transition!(from: "processing", to: "processing", paperless_task_id: task_id)
  end

  def note_poll!(attempts)
    transition!(from: "processing", to: "processing", poll_attempts: attempts)
  end

  def finish_processing!(document_id:)
    settled = transition!(from: "processing", to: "unlinked",
                          paperless_document_id: document_id, paperless_task_id: nil, failure_message: nil)
    # One choke point for the OCR-text snapshot: polling, the ingest webhook and
    # statement OCR all settle through this method. Idempotent and bounded.
    # (Ruling M7-L9, 2026-10-11 close-out) The enqueue is failure-SAFE, not
    # fire-and-forget: a transient enqueue failure (Sidekiq/Redis down) at this
    # choke point used to raise and strand the settled row with no re-drive (the
    # M1-Ruling-11 class). The settle stands — the row is unlinked with its
    # document id — and the row stays in `capture_pending_content`'s scope,
    # which SyncCleanerJob's hourly sweep re-drives without an operator.
    if settled
      begin
        Paperless::CaptureContentJob.perform_later(id)
      rescue => e
        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "CaptureContentJob enqueue failed: #{e.class}: #{e.message}",
          source: "document_link",
          family: family,
          metadata: { record_type: self.class.name, record_id: id, reason: "enqueue_failed" }
        )
      end
    end
    settled
  end

  # The OCR-text snapshot. Deliberately NOT a status transition: a `transition!`
  # in progress must not be clobbered by content capture. By default it is
  # idempotent — it fills only a blank column, so a replayed job or a backfill
  # can never overwrite a good snapshot. `refresh: true` is the native-read
  # escape hatch: a reprocess after a model (or engine) change MUST be able to
  # replace a bad snapshot; the paperless-era write-once contract existed only
  # because the snapshot arrived from someone else's engine, which is no longer
  # true.
  def record_content!(text, refresh: false)
    return false if text.blank?

    scope = self.class.where(id: id)
    scope = scope.where(extracted_text: nil) unless refresh
    scope.update_all(extracted_text: text.to_s.first(EXTRACTED_TEXT_LIMIT), updated_at: Time.current) == 1
  end

  # The native read settled: the row is read and ready to be classified, routed
  # (Task 8/9) or linked. Moves only this row's status — never money.
  def settle! = transition!(from: "processing", to: "unlinked", failure_message: nil)

  # The AI's class, written once the read settles. `source` was chosen by the user
  # in the paperless era (SourceGuesser or a wizard tile); it is now a fact about
  # the document.
  def classify!(document_class:, confidence:, classified_by:)
    self.class.where(id: id).update_all(
      source: document_class, classified_by: classified_by,
      classification_confidence: confidence, updated_at: Time.current
    )
  end

  # The settle-time tag snapshot (M8 locked decision 6), idempotent like
  # record_content!: it fills only while the column is empty, so a replayed job
  # or a backfill run can never overwrite names already resolved. A blank list
  # is a deliberate no-write — a genuinely tag-less document cannot record that
  # fact, so it stays in the backfill's scope and is re-fetched on a later run
  # (bounded; recorded in M8's self-review).
  def record_tags!(names)
    names = Array(names).map(&:to_s).reject(&:blank?).uniq
    return false if names.empty?

    self.class.where(id: id, tags: [])
        .update_all(tags: names, updated_at: Time.current) == 1
  end

  # The row's displayed "document date" MUST be the same coerced date the
  # range filter and the document_date sort use (Ruling M8-C3, 2026-10-11
  # close-out — they used to disagree for reachable states). Same precedence
  # as DocumentLink::Search::DOCUMENT_DATE_SQL: the latest UNDERSTOOD draft
  # whose raw extracted date passes the SQL's shape guard, else the upload
  # date. A needs_understanding draft carrying a date, or a newer draft that
  # is not understood, must not move the display away from that authority.
  def document_date
    draft = receipt_imports
      .select { |import| import.understanding_state == "understood" && import.extracted_data&.dig("date").to_s.match?(/\d{4}-\d{2}-\d{2}/) }
      .max_by(&:created_at)
    draft&.purchase_date || created_at.to_date
  end

  # The live row (M8 Task 9, Ruling M8-L1 decision 3): when a draft's
  # understanding settles, the archive's row re-renders in place over the
  # family stream every layout subscribes to, so "Reading…" flips to the review
  # affordance without a reload. The replaced row comes from the same factory
  # the index used; its viewer URL is the bare page URL (a broadcast has no
  # request carrying the index's filters, and the row must stay openable). The
  # replace is idempotent, so a repeated delivery is harmless.
  def broadcast_row_update!
    row = DocumentBrowser::Row.for_document_link(
      self, viewer_url: Rails.application.routes.url_helpers.viewer_document_path(self)
    )
    html = ApplicationController.render(partial: "document_browser/row", locals: { row: row }, formats: [ :html ])
    Turbo::StreamsChannel.broadcast_replace_to(family, target: ActionView::RecordIdentifier.dom_id(self), html: html)
  end

  def fail!(message)
    transition!(from: "processing", to: "failed",
                failure_message: message, paperless_task_id: nil)
  end

  # Paperless unreachable or the token rejected: keep the bytes, drop back to a
  # retryable state, no retry loop and no silent failure (spec §8.1, §8.6).
  def hold!(message: nil)
    transition!(from: %w[processing queued], to: "queued",
                paperless_task_id: nil, failure_message: message)
  end

  def retry_upload!
    transition!(from: %w[failed queued processing], to: "queued",
                paperless_task_id: nil, failure_message: nil, poll_attempts: 0)
  end

  # Writes the uploaded bytes to the staging volume and records their digest.
  # Guarded like every other write, so a row that moved on is not re-staged.
  def stage!(io:, filename:, content_type:)
    path = DocumentLink::Staging.write(io: io, id: id)
    digest = Digest::SHA256.file(path).hexdigest
    transition!(from: %w[queued processing failed], to: "queued",
                stored_path: path, content_sha256: digest,
                original_filename: filename, content_type: content_type)
  end

  def stored_io(&block)
    return nil if stored_path.blank?
    DocumentLink::Staging.open(stored_path, &block)
  end

  # Ruling M3 (M1), 2026-10-10 close-out: clearing the staged bytes must NOT
  # move the row's status. The previous form re-asserted the in-memory status as
  # the transition's target (`to: status`), so a row that had changed state
  # after it was loaded could be written back to a stale status. This clears
  # only the one column, in a direct update guarded by id.
  def delete_stored!
    DocumentLink::Staging.delete(stored_path)
    self.class.where(id: id).update_all(stored_path: nil, updated_at: Time.current)
  end

  # M3's matcher writes only through this guarded primitive (R4), so a cron tick
  # racing a user link/dismiss can never clobber the row. `ArgumentError` is
  # raised only for a status outside MATCHER_OUTCOMES; a stale row returns false.
  def record_match!(status:, confidence:)
    raise ArgumentError, "unknown matcher outcome: #{status}" unless MATCHER_OUTCOMES.include?(status.to_s)
    transition!(from: %w[unlinked suggested pending_review], to: status.to_s, confidence: confidence)
  end

  # NEVER touches the entry's money (D8): it writes only this row.
  def link_to_entry!(entry, confidence: nil)
    transition!(from: LINKABLE, to: "linked", entry_id: entry.id, confidence: confidence)
  end

  def unlink!
    transition!(from: STATUSES, to: "unlinked", entry_id: nil, confidence: nil)
  end

  def verify!
    transition!(from: "linked", to: "verified")
  end

  def dismiss!
    transition!(from: STATUSES - %w[verified dismissed], to: "dismissed")
  end
end
