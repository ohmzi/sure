# frozen_string_literal: true

# How and where a transaction was found in a document (the owner, 2026-10-17).
# Opened from a transaction, the viewer talks about that transaction: the
# statement line it came from as the statement printed it, the page it is on,
# and how it got into the account. Read-only.
#
# Three ways an entry and a document are related, and nothing else counts:
#   :created  — this document's import added the entry;
#   :verified — the entry was already there and this statement's line confirmed it;
#   :matched  — the document (a receipt) was matched to the entry.
class Entry::DocumentTrace
  Line = Data.define(:date, :name, :amount, :row_number, :page)

  # Two lines with the same amount a statement apart are told apart by date;
  # past this they are not the same money.
  DATE_REACH = 14

  attr_reader :entry, :link, :how

  def self.for(entry, link)
    how = relation(entry, link)
    how && new(entry, link, how)
  end

  def self.relation(entry, link)
    import = entry.import
    statement = entry.reconciled_by_statement

    if import && (import.document_link_id == link.id ||
                  (link.account_statement_id.present? && import.account_statement_id == link.account_statement_id))
      :created
    elsif statement && (statement.id == link.account_statement_id || statement.archived_document_link&.id == link.id)
      :verified
    elsif link.entry_id == entry.id
      :matched
    end
  end

  def initialize(entry, link, how)
    @entry = entry
    @link = link
    @how = how
  end

  # The statement line, as printed. nil for a receipt, or when no line of the
  # read carries this amount near this date.
  def line
    return @line if defined?(@line)

    @line = best_line
  end

  def page = line&.page || mark&.page

  # Where the line sits on its page, for the viewer to mark it.
  def mark
    return @mark if defined?(@mark)

    @mark = line && DocumentLink::LineLocator.new(link).locate(name: line.name, amount: line.amount, page: line.page)
  end

  def days_apart = line && (line.date - entry.date).abs.to_i
  def amount_matches? = line.present? && line.amount == entry.amount.abs

  # The date the document's evidence landed on the entry.
  def at
    case how
    when :created then entry.import&.created_at
    when :verified then entry.reconciled_at
    end
  end

  private
    def best_line
      amount = entry.amount.abs
      wanted = normalize(entry.name)

      candidates = read_lines.select { |candidate| candidate.amount == amount }
      exact = candidates.find { |candidate| normalize(candidate.name) == wanted }
      return exact if exact

      candidates
        .select { |candidate| (candidate.date - entry.date).abs <= DATE_REACH }
        .min_by { |candidate| [ (candidate.date - entry.date).abs, candidate.row_number ] }
    end

    # Every transaction the statement's read found, in the statement's order.
    def read_lines
      import = how == :created && entry.import.is_a?(PdfImport) ? entry.import : statement_import
      return [] unless import

      import.extracted_transactions.each_with_index.filter_map do |row, index|
        date = Date.iso8601(row["date"].to_s)
        amount = BigDecimal(row["amount"].to_s).abs
        Line.new(date:, name: row["name"].to_s, amount:, row_number: index + 1, page: row["source_page"].presence&.to_i)
      rescue ArgumentError, TypeError
        nil
      end
    end

    def statement_import
      scope = PdfImport.where(document_link_id: link.id)
      scope = scope.or(PdfImport.where(account_statement_id: link.account_statement_id)) if link.account_statement_id.present?
      scope.order(created_at: :desc).first
    end

    def normalize(text) = text.to_s.downcase.gsub(/[^a-z0-9]/, "")
end
