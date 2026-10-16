# frozen_string_literal: true

require "digest"

# The receipt/bill/statement spine. One row per uploaded document: it tracks the
# stored bytes and the optional link to an entry. Status changes go through
# `transition!` only — a single atomic conditional UPDATE, so a late write can
# never clobber a row the user already moved on.
class DocumentLink < ApplicationRecord
  STATUSES  = %w[queued processing unlinked suggested pending_review linked verified dismissed failed].freeze
  SOURCES   = %w[receipt bill statement other].freeze
  LINKABLE  = %w[unlinked suggested pending_review linked].freeze
  # The statuses a PUBLISH may record a provenance edge from (spec §8.5).
  # Wider than LINKABLE by `dismissed`: a user who dismissed the reconciliations
  # inbox's MATCHER suggestion has not refused to link the document to an entry
  # they then publish from it, and dropping the edge silently would leave
  # Milestone B's provenance ("which document did this come from") with no
  # answer. `link_to_entry!` still defaults to LINKABLE everywhere else.
  PUBLISH_LINKABLE = (LINKABLE + %w[dismissed]).freeze
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

  # The "what I understood" read for the viewer and the review screen. Prefers
  # the loaded collection when there is one: `.order(...).first` rebuilds a fresh
  # relation even on a preloaded association, so it would fire a query per
  # document in a loop (the transactions list's provenance, spec N13). `max_by`
  # over the loaded set is the same latest read, with no query.
  def extraction
    return document_extractions.max_by(&:created_at) if document_extractions.loaded?

    document_extractions.order(created_at: :desc).first
  end

  enum :source, { receipt: "receipt", bill: "bill", statement: "statement", other: "other" }, validate: true

  validates :status, inclusion: { in: STATUSES }

  scope :for_entry, ->(entry) { where(entry_id: entry.respond_to?(:id) ? entry.id : entry) }
  scope :ordered, -> { order(created_at: :desc) }
  # The archive (grid, strip, viewer walk) reads through here: a tombstone has
  # left the archive, so every one of those scopes must compose `not_deleted`.
  scope :not_deleted, -> { where(deleted_at: nil) }

  # The "the job died" shape (Task 11): mid-read or queued, has bytes, no stated
  # hold, and has not moved in a bound. DocumentReaperJob's scope — and it is
  # what makes "never a lost document" a property rather than a promise.
  #
  # `failure_message: nil` is the hold signal (fix round 1, item 2): `hold!`
  # lands a row in `queued` WITH a message, and the hold reasons that never
  # self-heal (no OCR configured, no provider configured, a document the engine
  # cannot read) would otherwise be re-enqueued every hour forever — re-running
  # OCR on an unreadable document indefinitely. Excluded here, they wait for a
  # reprocess or a new upload instead.
  #
  # Terminal rows (settled, failed) and byte-less rows are out too: there is
  # nothing to re-read, or nothing that can settle.
  def self.stranded(before:)
    where(status: %w[queued processing])
      .where.not(stored_path: nil)
      .where(failure_message: nil)
      .where("updated_at < ?", before)
  end

  class << self
    # The only way a row enters the system. The caller stages bytes
    # (DocumentLink#stage!, Task 3) and enqueues the native DocumentUnderstandingJob.
    def link_from_upload!(family:, uploader:, source:, title: nil)
      create!(family: family, created_by: uploader, source: source, title: title, status: "queued")
    end

    # Local OCR-context search (M8 locked decision 4 / M7 Task 10's pin): the
    # snapshot, the title and the filename. sanitize_sql_like keeps a typed % or
    # _ literal (the EntrySearch idiom).
    def search(query)
      term = query.to_s.strip
      return all if term.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      where("extracted_text ILIKE :p OR title ILIKE :p OR original_filename ILIKE :p", p: pattern)
    end

    # The tag facet's vocabulary (M8 Task 6): the distinct names stored in the
    # snapshot, so the choices render and filter locally. Callers pass the scope
    # whose tags they may show.
    def tag_snapshot_names(scope = all)
      scope.distinct.pluck(Arel.sql("unnest(tags)")).compact.sort
    end

    # The design's "needs you" scope (Milestone B, design D5): documents that
    # are waiting on a person. A held row (the reader stopped with a reason), a
    # draft waiting for review, or a statement with no account yet — the three
    # asks behind the strip's count, its list, and its "Show them" filter.
    def needs_attention(family)
      held = where(family: family).where.not(failure_message: nil)
      # A tombstone has left the archive, so it can never be "waiting on a
      # person" -- the strip's list and its count both drop it.
      ready_drafts = ReceiptImport.where(understanding_state: "understood")
                                  .where.not(status: "complete").select(:document_link_id)
      # A statement the read produced but never resolved to an account: the
      # "Which account?" tile state. `AccountStatement.unmatched` is exactly
      # "no account, not rejected", the same line the picker gates on.
      unmatched_statements = AccountStatement.unmatched.select(:id)
      held.or(where(family: family, id: ready_drafts))
          .or(where(family: family, account_statement_id: unmatched_statements))
          .not_deleted
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
      where(family: family).not_deleted.where(id: ready).count
    end
  end

  # The single write path for status changes. Moves the row only while it is
  # still in `from`; returns true when exactly one row moved. This is the
  # M2 ruling re-encoded: guarded, atomic, one writer.
  def transition!(from:, to:, **attributes)
    self.class.where(id: id, status: Array(from))
        .update_all(attributes.merge(status: to, updated_at: Time.current)) == 1
  end

  # A read is starting (or restarting). Clears any stale failure/backoff message
  # (fix round 2): without this, a row parked by `await_retry!` would carry its
  # message into `processing`, and the sweep — which excludes message-bearing
  # rows — would be blind to a genuine crash of the restarted read.
  def mark_processing!
    transition!(from: %w[queued failed processing], to: "processing", failure_message: nil)
  end

  # The read's liveness touch (Task 11 fix round 1, item 1). The `stranded`
  # sweep keys on a stale `updated_at`, so a read that is genuinely running must
  # keep its row fresh as it works: a heartbeat per step means the sweep can
  # never select an in-flight read, however far past the bound the read runs.
  # Guarded to the two non-terminal statuses so a late heartbeat cannot revive a
  # settled row's clock and drag it back into the sweep.
  def heartbeat!
    self.class.where(id: id, status: %w[queued processing]).update_all(updated_at: Time.current) == 1
  end

  # The OCR-text snapshot. Deliberately NOT a status transition: a `transition!`
  # in progress must not be clobbered by content capture. By default it is
  # idempotent — it fills only a blank column, so a replayed job or a backfill
  # can never overwrite a good snapshot. `refresh: true` is the native-read
  # escape hatch: a reprocess after a model (or engine) change MUST be able to
  # replace a bad snapshot.
  def record_content!(text, refresh: false)
    return false if text.blank?

    scope = self.class.where(id: id)
    scope = scope.where(extracted_text: nil) unless refresh
    scope.update_all(extracted_text: text.to_s.first(EXTRACTED_TEXT_LIMIT), updated_at: Time.current) == 1
  end

  # The native read settled: the row is read and ready to be classified, routed
  # (Task 8/9) or linked. Moves only this row's status — never money.
  def settle! = transition!(from: "processing", to: "unlinked", failure_message: nil)

  # The AI's class, written once the read settles. `source` is a fact about the
  # document, decided by the read's DocumentClassifier. `corroborated` is the
  # classifier's deterministic-witness verdict (spec §7.4, N6) — persisted so
  # the auto-post gate can require the witness, not merely the model's assertion.
  def classify!(document_class:, confidence:, classified_by:, corroborated:)
    self.class.where(id: id).update_all(
      source: document_class, classified_by: classified_by,
      classification_confidence: confidence,
      classification_corroborated: corroborated, updated_at: Time.current
    )
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

  # The live tile (M8 Task 9, Ruling M8-L1 decision 3; Milestone B Task 3): when
  # a draft's understanding settles, the Documents grid's tile re-renders in
  # place over the family stream every layout subscribes to, so "Reading…"
  # flips to the review state without a reload. The replaced tile comes from the
  # same factory the index used; its viewer URL is the bare page URL (a
  # broadcast has no request carrying the index's filters, and the tile must
  # stay openable). The replace is idempotent, so a repeated delivery is
  # harmless. The target id (dom_id) is the link's, and only the Documents grid
  # carries it — the Statements vault keys its rows by account_statement.
  def broadcast_row_update!
    row = DocumentBrowser::Row.for_document_link(
      self, viewer_url: Rails.application.routes.url_helpers.viewer_document_path(self)
    )
    html = ApplicationController.render(partial: "document_browser/tile", locals: { row: row }, formats: [ :html ])
    Turbo::StreamsChannel.broadcast_replace_to(family, target: ActionView::RecordIdentifier.dom_id(self), html: html)
  end

  def fail!(message)
    transition!(from: "processing", to: "failed", failure_message: message)
  end

  # The read could not run: keep the bytes, drop back to a retryable state, no
  # retry loop and no silent failure (spec §8.1, §8.6).
  def hold!(message: nil)
    transition!(from: %w[processing queued], to: "queued", failure_message: message)
  end

  # The retry ladder is waiting, not the user (Task 11 fix round 2). A transient
  # OCR failure re-raises for `retry_on`, and the row parks in `queued` WITH the
  # reason so the sweep leaves it alone for the whole backoff — the polynomial's
  # later waits far exceed the sweep's bound, and a sweep that selected a waiting
  # row would race the scheduled retry into a second OCR call, a second paid
  # provider call and a second DocumentExtraction. The retry still finds the row
  # (the job's guard accepts `queued`), and `mark_processing!` clears the message
  # when the read restarts, so a crash after the restart stays sweepable.
  def await_retry!(message:)
    transition!(from: %w[processing queued], to: "queued", failure_message: message)
  end

  # The retry ladder is spent: land the row terminally from whatever state it is
  # actually in. A backoff-parked row is `queued`, so `fail!`'s `processing`-only
  # guard would no-op and leave a spent row parked forever.
  def abandon!(message:)
    transition!(from: %w[processing queued], to: "failed", failure_message: message)
  end

  def retry_upload!
    transition!(from: %w[failed queued processing], to: "queued", failure_message: nil)
  end

  # A fresh read of the same document: clears the terminal bits and re-queues.
  # It deliberately does NOT unlink an entry — reprocessing the READ must never
  # move money (D8). A published receipt's provenance link survives a reprocess.
  # The second, unconditional updated_at bump gives the re-queued row a clean
  # `stranded` clock, so a reaper tick cannot re-select it before the fresh job
  # has had its bound.
  def reprocess!
    transition!(from: STATUSES, to: "queued", failure_message: nil) &&
      self.class.where(id: id).update_all(updated_at: Time.current) == 1
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
    # The rendered preview is derived from these bytes, so it goes with them —
    # otherwise a tombstone would keep serving a picture of a document it no
    # longer holds.
    DocumentLink::Thumbnail.delete(self)
    DocumentLink::OcrCache.delete(self)
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

  # NEVER touches the entry's money (D8): it writes only this row. `from:`
  # defaults to LINKABLE; the publish-time provenance write may widen it (see
  # PUBLISH_LINKABLE) but every other caller keeps the default contract.
  def link_to_entry!(entry, confidence: nil, from: LINKABLE)
    transition!(from: from, to: "linked", entry_id: entry.id, confidence: confidence)
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

  # --- delete-block and tombstone (spec N9) ---------------------------------
  #
  # Money is never silently cascaded, and a document's provenance is never
  # silently lost. The delete is refused while anything DERIVED is unreconciled;
  # when it is clear, the bytes go and the row stays as a tombstone, so the entry
  # it produced still tells the truth about where it came from.

  # Every entry this document produced or corroborates. Three routes, and each
  # matters: an entry a draft produced hangs off `entries.import_id ->
  # imports.document_link_id`; an entry a STATEMENT's import produced hangs off
  # `entries.import_id -> imports.account_statement_id` (an OFX/QFX bank export
  # carries NO document_link -- it is an "Import file", spec §8.6 -- so the
  # document_link route alone cannot see its rows); and an entry a document was
  # merely MATCHED to hangs off `document_links.entry_id`. Missing any of them
  # would let a delete cascade over money or orphan a corroboration.
  def derived_entries
    produced = Entry.where(import_id: Import.where(document_link_id: id).select(:id))
    corroborated = Entry.where(id: entry_id)
    scope = produced.or(corroborated)
    return scope if account_statement_id.blank?

    scope.or(Entry.where(import_id: Import.where(account_statement_id: account_statement_id).select(:id)))
  end

  # The refusal NAMES what is in the way -- a blocking rule the user cannot act
  # on, and cannot see, is a wall. Unreconciled entries only: a reconciled entry
  # is settled evidence, safe to leave behind as a tombstoned provenance trail.
  def deletion_blockers
    derived_entries.reject(&:reconciled?).map(&:name)
  end

  def deletable? = deletion_blockers.empty?

  # The bytes go, the row stays. Guarded by `deletable?` so a soft delete can
  # never cascade over an unreconciled entry: the row is hidden from the archive
  # but keeps answering "where did this entry come from" forever.
  def soft_delete!
    raise "document has unreconciled derived entries" unless deletable?

    transaction do
      delete_stored!
      # The digest is the claim "these bytes are mine". A document that has given
      # up its bytes gives up that claim too: the (family, content_sha256) unique
      # index is predicated on `content_sha256 IS NOT NULL`, and Intake's dedup
      # check matches any row holding the digest, so clearing it lets the same
      # file be re-added instead of being refused as a duplicate while no visible
      # copy exists.
      self.class.where(id: id).update_all(deleted_at: Time.current, content_sha256: nil,
                                          updated_at: Time.current)
    end
  end

  def deleted? = deleted_at.present?

  # The carried-in Task 9 gap. `data_committed?` is `entries.exists?`, so the
  # auto-post undo clears it and a reprocess would silently re-post what the user
  # took back. This records the reversal ON THE DOCUMENT -- the identity the
  # auto-post is keyed on -- so the gate can refuse it durably. The reviewed
  # publish is unaffected: the user can still redo by publishing by hand.
  def auto_post_undone? = auto_post_undone_at.present?

  def mark_auto_post_undone!
    self.class.where(id: id).update_all(auto_post_undone_at: Time.current, updated_at: Time.current) == 1
  end
end
