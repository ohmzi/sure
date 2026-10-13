# frozen_string_literal: true

# Where did this entry come from? Exactly one answer, of four (spec N13).
#
# The app already knows: a provider slug lands in `entries.source`, a file
# import stamps `import_locked`, a document writes `source: "document"`, and a
# matched document hangs off `entries.document_links`. This resolves those into
# one primary source plus a corroborating list, so a row never has to guess and
# a UI never has to say "maybe".
#
# Read-only: it writes nothing, anywhere, and never touches money.
class EntryProvenance
  SOURCES = %w[document import_file synced manual].freeze

  attr_reader :entry

  def self.for(entry) = new(entry)

  def initialize(entry)
    @entry = entry
  end

  # The single answer. Precedence is top to bottom, so a receipt the bank later
  # matched is a document -- a corroborated one, not a competing `synced` row.
  def primary
    return "document" if document_backed?
    return "import_file" if file_import?
    return "synced" if @entry.source.present?

    "manual"
  end

  # Additive, never a second primary: the receipts and statements that matched
  # this entry. This is what makes "one transaction, two sources" expressible.
  # Memoised (the link set is loaded once) so a list render that asks for
  # `primary`, `documents` and `edited?` pays for it a single time.
  def documents
    @documents ||= @entry.document_links.to_a
  end

  # The two-source case (spec §8.6): "a receipt matched to a statement row, or
  # vice versa". Corroborated means a linked document that did NOT create this
  # entry -- a document a provider row, a file import, a hand entry OR another
  # document later matched. The creating link is the one the entry's import
  # hangs the entry off, so any other linked document is the second source. A
  # receipt whose only origin is its own document is not corroborated.
  #
  # The identity is `import.document_link_id` because that IS the creating
  # document: a receipt's ReceiptImport carries the receipt link, and a
  # statement's PdfImport carries the statement's own archived link
  # (`create_from_statement!`). So a statement-born entry's creating document is
  # on the import too, and attaching the statement's own link to such an entry
  # would NOT read as corroboration -- it equals the creating link and reads as
  # the source (Task 7's `claim!` still only touches pre-existing MATCHED
  # entries, whose import is not this statement's).
  def corroborated?
    creating_link_id = @entry.import&.document_link_id
    documents.any? { |document| document.id != creating_link_id }
  end

  # The document that PRODUCED this entry, when it is not already one of
  # `documents`. A statement-born row hangs off `import.document_link` (spec N13:
  # import_id -> import -> document_link), the statement's archived copy, and
  # that link lives on the import, never on `entry.document_links` -- so the
  # corroboration chips render nothing for a row whose whole origin is that
  # document, and the row names "from a document" with no chip back to it. This
  # exposes the producing link so the row can offer the same chip. It is the
  # SOURCE, not corroboration: it is deliberately kept out of `documents`, which
  # `corroborated?` reads, so a document can never corroborate the entry it
  # created. When the producing link IS attached to the entry (a receipt, whose
  # link carries the entry_id), it is already a `document` and returns nil here,
  # so the view renders it exactly once.
  def producing_document
    return @producing_document if defined?(@producing_document)

    link = @entry.import&.document_link
    @producing_document =
      link && documents.none? { |document| document.id == link.id } ? link : nil
  end

  # "edited by you" (spec N13): the displayed value no longer equals what the
  # document said. Comparing the numbers is the whole point -- a flag that only
  # meant "someone touched this row" would not tell the user the value moved.
  # Defensive by construction: the read is the typed, unparseable-reads-as-nil
  # view (DocumentUnderstanding), so a garbage total or date is `false`, never
  # a raise.
  def edited?
    understanding = latest_understanding
    return false if understanding.nil?

    document_total = understanding.total
    document_date = understanding.date
    return false if document_total.nil? && document_date.nil?

    (document_total.present? && document_total != @entry.amount) ||
      (document_date.present? && document_date != @entry.date)
  end

  def label = I18n.t("entries.provenance.#{primary}")

  # The document that produced this entry is gone: its bytes are deleted but the
  # row survives precisely so this question has an honest answer. The entry is
  # NOT edited or reattributed -- it still belongs to a document; that document
  # simply no longer exists (task 10, spec N9).
  def source_deleted? = documents.any? { |link| link.deleted_at.present? }

  private
    def document_backed?
      documents.any? ||
        @entry.import&.document_link.present? ||
        @entry.source == "document"
    end

    def file_import?
      @entry.import.present? || @entry.import_locked? || @entry.source == "ofx"
    end

    # The latest read across every document on this entry, as `DocumentUnderstanding`
    # -- the one definition of "a parseable amount" and a parseable date. A
    # verdict that is not a hash (the column is jsonb, default {}) reads as nil.
    def latest_understanding
      extraction = documents.filter_map(&:extraction).max_by(&:created_at)
      return nil unless extraction&.verdict.respond_to?(:with_indifferent_access)

      DocumentUnderstanding.new(extraction.verdict)
    end
end
