# frozen_string_literal: true

# A transfer's proof (the owner, 2026-10-17): the same amount left one account
# and arrived in another, how many days apart, and the statement that shows
# each side. Seen on both banks' statements is the strongest proof a transfer
# can have; a match with no statement behind it is only the amounts and dates
# agreeing.
class Transfer::Evidence
  Side = Data.define(:direction, :entry, :account, :document) do
    def witnessed? = document.present? && document.deleted_at.nil?
  end

  attr_reader :transfer

  def initialize(transfer)
    @transfer = transfer
  end

  # Money out first, then money in.
  def sides
    @sides ||= [ [ :out, transfer.outflow_transaction ], [ :in, transfer.inflow_transaction ] ].map do |direction, transaction|
      entry = transaction.entry
      Side.new(direction:, entry:, account: entry.account, document: witnessing_document(entry))
    end
  end

  def days_apart
    (sides.first.entry.date - sides.last.entry.date).abs.to_i
  end

  # :both — each bank's statement shows its side; :one — only one does;
  # :none — the match rests on the amounts and dates alone.
  def witness
    case sides.count(&:witnessed?)
    when 2 then :both
    when 1 then :one
    else :none
    end
  end

  private
    # The statement that shows this side: the one whose import created the row,
    # else the one whose rows verified it afterwards (a chequing row is often
    # entered by the bank feed and reconciled against its statement later).
    def witnessing_document(entry)
      EntryProvenance.for(entry).creating_document || entry.reconciled_by_statement&.archived_document_link
    end
end
