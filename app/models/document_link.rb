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
  SETTLEABLE = %w[processing].freeze
  # The only statuses `record_match!` may write (R4). `:no_match` is a deliberate
  # no-write on M3's side, so it is not a writable outcome here.
  MATCHER_OUTCOMES = %w[suggested pending_review].freeze

  belongs_to :family
  belongs_to :entry, optional: true
  belongs_to :account_statement, optional: true
  belongs_to :created_by, class_name: "User", optional: true

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
    transition!(from: "processing", to: "unlinked",
                paperless_document_id: document_id, paperless_task_id: nil, failure_message: nil)
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
                staged_path: path, content_sha256: digest,
                original_filename: filename, content_type: content_type)
  end

  def staged_io(&block)
    return nil if staged_path.blank?
    DocumentLink::Staging.open(staged_path, &block)
  end

  def delete_staged!
    DocumentLink::Staging.delete(staged_path)
    transition!(from: STATUSES, to: status, staged_path: nil)
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
