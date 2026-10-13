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

  # The two-source case: a document corroborates an entry a document did not
  # itself create -- a provider row or a file import a receipt later matched.
  # A receipt whose only origin is its own document is not corroborated: there
  # is nothing else agreeing with it.
  def corroborated?
    documents.any? && @entry.source != "document"
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
