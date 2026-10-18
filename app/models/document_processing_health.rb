# frozen_string_literal: true

# A small read-only view of the document pipeline for the admin health page.
# The durable retry columns on DocumentLink are the source of truth; this is
# the operator's summary of where reads and their imports stand right now.
#
# The read outcomes are separated by what the pipeline actually persisted:
# `proven`/`unverified` come from the latest extraction's validators (a
# non-statement read is proven when it succeeded; a statement must have
# reconciled to its printed totals), `held` is a stopped read waiting on a
# person, `retrying` is a scheduled automatic retry, and `exhausted` is a spent
# retry budget.
class DocumentProcessingHealth
  # A read that finished and settled into one of these states. `settle!` moves
  # a successful read out of `processing`; every later lifecycle change keeps
  # one of these statuses except a hold (queued/failed).
  SETTLED_STATUSES = %w[unlinked suggested pending_review linked verified dismissed].freeze
  # The reconciliation matcher's two outcomes: the document is waiting on a
  # person to confirm or dismiss the suggested entry.
  REVIEW_STATUSES = %w[suggested pending_review].freeze

  # The latest read of each document. `DocumentLink#extraction` uses the same
  # ordering; the lateral join lets the counters stay one query each instead of
  # loading every link and its reads into Ruby.
  LATEST_EXTRACTION = <<~SQL.squish
    LEFT JOIN LATERAL (
      SELECT status, validations
      FROM document_extractions
      WHERE document_extractions.document_link_id = document_links.id
      ORDER BY document_extractions.created_at DESC, document_extractions.id DESC
      LIMIT 1
    ) latest_extraction ON TRUE
  SQL

  attr_reader :family

  def initialize(family)
    @family = family
  end

  def documents = scope.count
  def in_flight = scope.where(status: %w[queued processing]).count
  def retrying = scope.where.not(next_attempt_at: nil).where("next_attempt_at > ?", Time.current).count
  def exhausted = scope.where(failure_code: "retry_exhausted").count

  # A stopped read that is not waiting out a scheduled retry. A terminal hold
  # needs a person (a reprocess, a setting, or a different file); a retry whose
  # due time has passed needs the reaper to pick it up. Both are visible here
  # instead of silently parked.
  def held
    scope.where(status: %w[queued failed])
         .where.not(failure_message: nil)
         .where("failure_code IS NULL OR failure_code <> 'retry_exhausted'")
         .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
         .count
  end

  # Reads the reconciliation matcher routed to the owner.
  def awaiting_review = scope.where(status: REVIEW_STATUSES).count

  # A succeeded read whose result can be trusted: every non-statement read, or
  # a statement whose rows reconciled to its printed totals.
  def proven
    succeeded_reads
      .where("document_links.source <> 'statement' " \
             "OR latest_extraction.validations ->> 'statement_totals_reconcile' = 'true'")
      .count
  end

  # A statement read that could not be proven against its printed totals
  # (nothing to check it against, or it did not add up). Never treated as a
  # trusted read; it waits for review.
  def unverified
    succeeded_reads
      .where(source: "statement")
      .where("latest_extraction.validations ->> 'statement_totals_reconcile' IS DISTINCT FROM 'true'")
      .count
  end

  def pending_imports
    family.imports.where(status: "pending").where.not(document_link_id: nil).count
  end

  def healthy? = exhausted.zero? && retrying.zero? && pending_imports.zero?

  private
    def scope = family.document_links.not_deleted

    def succeeded_reads
      scope.where(status: SETTLED_STATUSES)
           .joins(LATEST_EXTRACTION)
           .where("latest_extraction.status = 'succeeded'")
    end
end
