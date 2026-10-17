# frozen_string_literal: true

class DocumentLinkPanelComponent < ApplicationComponent
  CANDIDATE_LIMIT = 5

  def initialize(entry:)
    @entry = entry
  end

  attr_reader :entry

  # The owner's rule (2026-10-17): a transaction's details show the document
  # it came from and the ones linked to it — never the family's other
  # documents. The source is listed first and cannot be unlinked (it made the
  # row); a receipt is offered only when its read matches this transaction.
  MATCH_TOLERANCE = BigDecimal("0.01")
  MATCH_DAYS = 10
  CANDIDATE_POOL = 50

  def source_document
    return @source_document if defined?(@source_document)

    @source_document = EntryProvenance.for(entry).creating_document
  end

  def documents
    @documents ||= DocumentLink.for_entry(entry).ordered.reject { |document| document.id == source_document&.id }
  end

  def candidates
    @candidates ||= begin
      amount = entry.amount.to_d.abs
      DocumentLink.where(family_id: entry.account.family_id, status: "unlinked")
                  .includes(:document_extractions).ordered.limit(CANDIDATE_POOL)
                  .select { |document| matches_entry?(document, amount) }
                  .first(CANDIDATE_LIMIT)
    end
  end

  private
    # Same amount (to the cent) and, when the read has one, a date within
    # MATCH_DAYS of the entry's.
    def matches_entry?(document, amount)
      verdict = document.extraction&.verdict.to_h
      total = BigDecimal(verdict["total"].to_s, exception: false)
      return false unless total && (total.abs - amount).abs <= MATCH_TOLERANCE

      date = begin
        Date.iso8601(verdict["date"].to_s)
      rescue Date::Error
        nil
      end
      date.nil? || (date - entry.date).abs <= MATCH_DAYS
    end
end
