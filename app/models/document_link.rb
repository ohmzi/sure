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

  # --- durable retry state (2026-10-17) -------------------------------------
  # The row, not Redis, is the source of truth for an unfinished read. A lost
  # job or a reboot resumes from here; the reaper only has to find it.
  PROCESSING_LEASE = 30.minutes
  MAX_RETRY_ATTEMPTS = 20
  MAX_RETRY_AGE = 7.days
  # An unexpected (non-provider, non-OCR) error is usually a bug; retry it a
  # few times, but do not spend a week of paid reads on a deterministic one.
  READ_ERROR_ATTEMPTS = 3
  RETRY_BACKOFF = [ 1.minute, 5.minutes, 15.minutes, 30.minutes, 1.hour ].freeze

  belongs_to :family
  belongs_to :entry, optional: true
  belongs_to :account_statement, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  # A hard delete (a family's dependent destroy) must take the staged bytes and
  # their derived previews with it. Soft deletes already do this themselves;
  # this is the last line that keeps deleted households from leaving documents
  # on the volume forever.
  after_destroy :delete_stored!
  before_destroy :remember_stored_path_for_delete!

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
      # A transient failure keeps its reason but stays sweepable. A terminal
      # one is left for the archive's Retry button; retrying it forever would
      # re-OCR a file the engine cannot read.
      .where("(failure_code IS NULL OR failure_code IN (?))", DocumentHold::RETRYABLE_CODES)
      .where(
        # A scheduled retry is due at its own time. Everything else waits for
        # the lease/grace bound, so a freshly uploaded row is never raced by a
        # sweep enqueuing a second job.
        "((next_attempt_at IS NOT NULL AND next_attempt_at <= ?) " \
        "OR (next_attempt_at IS NULL AND updated_at < ? AND " \
        "(failure_message IS NULL OR failure_code IS NOT NULL)) " \
        "OR (status = 'processing' AND attempts_count = 0))",
        Time.current, before
      )
  end

  class << self
    # The only way a row enters the system. The caller stages bytes
    # (DocumentLink#stage!, Task 3) and enqueues the native DocumentUnderstandingJob.
    def link_from_upload!(family:, uploader:, source:, title: nil, currency: nil)
      create!(family: family, created_by: uploader, source: source, title: title, status: "queued", currency: currency)
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
    # draft waiting for review, or a statement with no account yet — the asks
    # behind the strip's count, its list, and its "Show them" filter.
    #
    # P1.11 adds the data-quality asks: a statement whose stored period is
    # incomplete, or which prints no identity to match an account by. Both are
    # things the owner can fix on the statement page, and both would otherwise
    # sit silently in the vault.
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
      # A rejected statement is not waiting on anyone, so its missing metadata
      # is not an ask.
      incomplete_statements = AccountStatement.where(family: family)
                                               .where.not(review_status: "rejected")
                                               .merge(AccountStatement.incomplete_metadata)
                                               .select(:id)
      held.or(where(family: family, id: ready_drafts))
          .or(where(family: family, account_statement_id: unmatched_statements))
          .or(where(family: family, account_statement_id: incomplete_statements))
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
    transition!(from: %w[queued failed processing], to: "processing",
                failure_message: nil, failure_code: nil, next_attempt_at: nil)
  end

  # Atomically take the read for this process. The conditional UPDATE is the
  # lease: a queued row is claimable at once; a `processing` row only once its
  # heartbeat (`updated_at`, kept fresh by #heartbeat!) is older than the lease.
  # Two jobs for the same document — a re-delivery and a reaper tick, say —
  # therefore cannot both read it. `attempts_count` moves here so the retry
  # budget travels with the row, not the job.
  def claim_for_processing!(lease: PROCESSING_LEASE, ignore_schedule: false, owner: nil)
    scope = self.class
                .where(id: id, status: %w[queued processing])
                # A `processing` row with no attempt is a pre-lease row (or one
                # whose claim never completed): no new-code read owns it, so a
                # boot sweep may take it immediately instead of waiting out the
                # lease. New claims always increment the counter.
                .where("status = 'queued' OR updated_at < ? OR (status = 'processing' AND attempts_count = 0)", lease.ago)
    # A retry the owner chose ("Retry with online AI") runs now, even if an
    # automatic retry is already scheduled; an automatic run waits its turn.
    scope = scope.where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current) unless ignore_schedule

    updated = scope
                  .update_all(
                    status: "processing",
                    failure_message: nil,
                    failure_code: nil,
                    next_attempt_at: nil,
                    attempts_count: Arel.sql("attempts_count + 1"),
                    processing_owner: owner,
                    updated_at: Time.current
                  )

    updated == 1
  end

  # Re-queue a row whose worker is gone, keeping its retry budget. Used by the
  # startup/reaper sweep when the owning Sidekiq process is no longer alive.
  def resume!
    transition!(from: "processing", to: "queued", failure_message: nil, failure_code: nil,
                next_attempt_at: nil, processing_owner: nil)
  end

  # Any `processing` row whose owner is not in the live Sidekiq process set was
  # interrupted by a reboot/deploy. Resume it now instead of waiting out the
  # 30-minute heartbeat lease. A live-but-hung process is still covered by the
  # lease; only genuinely absent processes are reclaimed here.
  def self.recover_orphaned_processing!
    alive = begin
      Sidekiq::ProcessSet.new.map { |process| "#{process['hostname']}:#{process['pid']}" }
    rescue StandardError => e
      Rails.logger.warn("[DocumentReaper] Could not read the Sidekiq process set: #{e.class}: #{e.message}")
      return 0
    end

    count = 0
    where(status: "processing").find_each do |link|
      # A nil owner is a pre-owner row (or an interrupted claim); the normal
      # lease covers it. Only a named owner that is gone is an immediate orphan.
      next if link.processing_owner.blank? || alive.include?(link.processing_owner)
      next unless link.resume!

      DocumentUnderstandingJob.perform_later(link.id)
      count += 1
    end
    count
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
  def settle!
    transition!(from: "processing", to: "unlinked", failure_message: nil,
                failure_code: nil, next_attempt_at: nil)
  end

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

  # --- duplicate review (2026-10-17) ---------------------------------------
  # A second statement for the same account and the same printed period is a
  # duplicate: one account cannot have two statements covering one cycle.
  # Grouping on the statement's own period (not the filename) is what lets the
  # review screen show the copies together and let a person fix a wrong
  # account/period or delete the extra.
  def duplicate_documents
    statement = account_statement
    return self.class.none unless statement&.account_id && statement.period_start_on && statement.period_end_on

    self.class.not_deleted
        .joins(:account_statement)
        .where.not(id: id)
        .where(account_statements: {
          account_id: statement.account_id,
          period_start_on: statement.period_start_on,
          period_end_on: statement.period_end_on
        })
  end

  def duplicate_group = [ self, *duplicate_documents.to_a ]

  def duplicate_group?
    duplicate_documents.exists?
  end

  # The earliest upload is the one the review list shows; the later copies are
  # the ones a person reviews beside it.
  def duplicate_representative?
    return false unless duplicate_group?

    duplicate_group.min_by { |link| [ link.created_at, link.id ] }.id == id
  end

  # The structured statement_duplicate hold is how a copy is marked; the bare
  # failure message alone could belong to any hold.
  def duplicate_held?
    hold_reason&.code == "statement_duplicate"
  end

  # One document id per duplicate group, for the Documents page's Duplicates
  # filter. Groups are (account, printed period); the earliest row represents.
  def self.duplicate_representative_ids(family)
    scope = family.document_links.not_deleted
                  .joins(:account_statement)
                  .where.not(account_statements: { account_id: nil })
                  .where.not(account_statements: { period_start_on: nil })
                  .where.not(account_statements: { period_end_on: nil })

    groups = scope.group(
      "account_statements.account_id",
      "account_statements.period_start_on",
      "account_statements.period_end_on"
    ).having("COUNT(*) > 1").pluck(
      "account_statements.account_id", "account_statements.period_start_on", "account_statements.period_end_on"
    )

    groups.filter_map do |account_id, period_start_on, period_end_on|
      scope.where(account_statements: {
                    account_id: account_id,
                    period_start_on: period_start_on,
                    period_end_on: period_end_on
                  })
           .order(:created_at, :id)
           .limit(1)
           .pick(:id)
    end
  end

  # The duplicate count for each link, in one grouped query (P1.12). Same
  # identity and scope as #duplicate_documents — another live document for the
  # same account and printed period — so a page full of rows no longer runs a
  # COUNT per row. Keys are link ids; links outside any group count 0.
  def self.duplicate_counts(links)
    links = Array(links)
    return {} if links.empty?

    identities = links.filter_map { |link| duplicate_identity(link) }.uniq
    return links.to_h { |link| [ link.id, 0 ] } if identities.empty?

    conditions = identities.map do
      "(account_statements.account_id = ? AND account_statements.period_start_on = ? " \
        "AND account_statements.period_end_on = ?)"
    end
    totals = not_deleted
             .joins(:account_statement)
             .where(conditions.join(" OR "), *identities.flatten(1))
             .group("account_statements.account_id", "account_statements.period_start_on",
                    "account_statements.period_end_on")
             .count

    links.to_h do |link|
      identity = duplicate_identity(link)
      [ link.id, identity ? [ totals.fetch(identity, 0) - 1, 0 ].max : 0 ]
    end
  end

  def self.duplicate_identity(link)
    statement = link.account_statement
    return unless statement&.account_id && statement.period_start_on && statement.period_end_on

    [ statement.account_id, statement.period_start_on, statement.period_end_on ]
  end
  private_class_method :duplicate_identity

  # The transaction-index filters that show this statement's rows: its account
  # and the period the statement prints (the whole cycle, not just one day).
  # A receipt/bill returns nil — its linked entry is the better target — and so
  # does a statement whose period was not read.
  def transaction_index_filters
    statement = account_statement
    return nil unless statement&.account_id && statement.period_start_on && statement.period_end_on

    {
      account_ids: [ statement.account_id ],
      start_date: statement.period_start_on.iso8601,
      end_date: statement.period_end_on.iso8601
    }
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

  # Why the row is held, with the actions that can fix it (spec §6) — nil when
  # it is not held. A hold from before structured holds existed (a bare
  # message) still explains itself and offers a retry.
  def hold_reason
    return nil if failure_message.blank?

    stored = extraction&.validations&.dig("hold")
    stored ? DocumentHold.from_h(stored) : DocumentHold.named("read_error", message: failure_message)
  end

  # Holds the row with a structured reason. The reason is kept on the read it
  # belongs to when there is one (a check that held a read which worked), else
  # on a failed read record of its own, so the archive can always say why.
  def hold_for!(hold, extraction: nil, validations: {}, from: %w[processing queued], **read_details)
    if extraction
      extraction.update!(validations: extraction.validations.merge("hold" => hold.to_h))
    else
      DocumentExtraction.record!(document_link: self, status: "failed", error: hold.message,
                                 validations: validations.merge("hold" => hold.to_h), **read_details)
    end
    if hold.retryable?
      schedule_retry!(message: hold.message, code: hold.code, from: from)
    else
      transition!(from: from, to: "queued", failure_message: hold.message,
                  failure_code: hold.code, next_attempt_at: nil)
    end
  end

  # A transient failure schedules itself. The row is the source of truth: the
  # delayed job is the fast path, and DocumentReaperJob catches the row if that
  # job (or Redis) is lost. After MAX_RETRY_ATTEMPTS / MAX_RETRY_AGE the read
  # stops with a visible terminal reason and the archive's Retry button.
  def schedule_retry!(message:, code:, from: %w[processing queued])
    unless retry_budget_left?(code)
      return transition!(
        from: from, to: "failed",
        failure_message: I18n.t("document_links.retry_exhausted", reason: message, count: attempts_count),
        failure_code: "retry_exhausted", next_attempt_at: nil
      )
    end

    delay = retry_delay
    scheduled = transition!(from: from, to: "queued",
                            failure_message: message, failure_code: code,
                            next_attempt_at: Time.current + delay)
    enqueue_retry(delay) if scheduled
    scheduled
  end

  # Whether the row is waiting for an automatic retry (as opposed to a terminal
  # hold the owner must resolve).
  def retrying?
    next_attempt_at.present? && DocumentHold::RETRYABLE_CODES.include?(failure_code.to_s)
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
  def await_retry!(message:, code: "ocr_unreachable", delay: 1.hour)
    transition!(from: %w[processing queued], to: "queued", failure_message: message,
                failure_code: code, next_attempt_at: Time.current + delay)
  end

  # The retry ladder is spent: land the row terminally from whatever state it is
  # actually in. A backoff-parked row is `queued`, so `fail!`'s `processing`-only
  # guard would no-op and leave a spent row parked forever.
  def abandon!(message:)
    transition!(from: %w[processing queued], to: "failed", failure_message: message,
                failure_code: "retry_exhausted", next_attempt_at: nil)
  end

  def retry_upload!
    transition!(from: %w[failed queued processing], to: "queued", failure_message: nil,
                failure_code: nil, next_attempt_at: nil, attempts_count: 0)
  end

  # A fresh read of the same document: clears the terminal bits and re-queues.
  # It deliberately does NOT unlink an entry — reprocessing the READ must never
  # move money (D8). A published receipt's provenance link survives a reprocess.
  # The second, unconditional updated_at bump gives the re-queued row a clean
  # `stranded` clock, so a reaper tick cannot re-select it before the fresh job
  # has had its bound.
  def reprocess!
    transition!(from: STATUSES, to: "queued", failure_message: nil,
                failure_code: nil, next_attempt_at: nil, attempts_count: 0) &&
      self.class.where(id: id).update_all(updated_at: Time.current) == 1
  end

  # Writes the uploaded bytes to the staging volume and records their digest.
  # Guarded like every other write, so a row that moved on is not re-staged.
  def stage!(io:, filename:, content_type:)
    path = DocumentLink::Staging.write(io: io, id: id)
    digest = Digest::SHA256.file(path).hexdigest
    # Restaging replaces the bytes at the same path. The page count and the
    # durable text layer were read from the old bytes, so they leave with them
    # (the text layer is named for the digest, but the old file must not linger);
    # an identical digest still describes the same bytes and stays cached.
    replaced = content_sha256 != digest
    DocumentLink::TextLayer.delete(self) if replaced
    attributes = { stored_path: path, content_sha256: digest,
                   original_filename: filename, content_type: content_type }
    attributes[:page_count] = nil if replaced
    transition!(from: %w[queued processing failed], to: "queued", **attributes)
  end

  def stored_io(&block)
    return nil if stored_path.blank?
    DocumentLink::Staging.open(stored_path, &block)
  end

  # A programmatic `stage!` uses a guarded update_all and leaves the in-memory
  # row stale. Re-read the path before the row is gone so the after_destroy
  # cleanup still finds the bytes.
  def remember_stored_path_for_delete!
    self.stored_path ||= self.class.where(id: id).pick(:stored_path)
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
    DocumentLink::TextLayer.delete(self)
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
  #
  # Returns false (writing nothing, including no bytes) when a derived entry is
  # still unreconciled. A refusal is a callers' branch, not an exception: the
  # statement delete path rolls its own transaction back and reports the
  # blocker, and an unhandled raise there was a 500.
  def soft_delete!
    return false unless deletable?

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
    true
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

  private
    # A deterministic failure (an unexpected exception) gets a short leash; a
    # provider/GPU/OCR outage gets the full horizon.
    def retry_budget_left?(code)
      limit = code.to_s == "read_error" ? READ_ERROR_ATTEMPTS : MAX_RETRY_ATTEMPTS
      attempts_count.to_i < limit && created_at > MAX_RETRY_AGE.ago
    end

    # attempts_count was incremented by claim_for_processing!, so the first
    # failure (1) waits one minute, then five, fifteen, thirty, and an hour.
    def retry_delay
      index = [ attempts_count.to_i - 1, 0 ].max
      RETRY_BACKOFF[index.clamp(0, RETRY_BACKOFF.length - 1)]
    end

    def enqueue_retry(delay)
      DocumentUnderstandingJob.set(wait: delay).perform_later(id)
    rescue => e
      # The row already carries next_attempt_at; the reaper is the backstop when
      # the fast path (a delayed job) cannot be written.
      Rails.logger.warn(
        "DocumentLink #{id}: could not enqueue the scheduled retry " \
        "(#{e.class}: #{e.message}); the reaper will pick it up"
      )
    end
end
