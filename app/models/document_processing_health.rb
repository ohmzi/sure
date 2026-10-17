# frozen_string_literal: true

# A small read-only view of the document pipeline for the admin health page.
# The durable retry columns on DocumentLink are the source of truth; this is
# the operator's summary of where reads and their imports stand right now.
class DocumentProcessingHealth
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def documents = scope.count
  def in_flight = scope.where(status: %w[queued processing]).count
  def retrying = scope.where.not(next_attempt_at: nil).where("next_attempt_at > ?", Time.current).count
  def exhausted = scope.where(failure_code: "retry_exhausted").count

  def awaiting_review
    scope.where(status: "queued").where.not(failure_message: nil)
         .where("failure_code IS NULL OR failure_code IN (?)", DocumentHold::TERMINAL_CODES)
         .count
  end

  def pending_imports
    family.imports.where(status: "pending").where.not(document_link_id: nil).count
  end

  def healthy? = exhausted.zero? && retrying.zero? && pending_imports.zero?

  private
    def scope = family.document_links.not_deleted
end
