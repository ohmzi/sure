require "test_helper"

# Where an entry came from, resolved from data the app already holds (spec N13).
# The four-source taxonomy has a strict precedence (document > import_file >
# synced > manual), and `documents` is additive: a receipt a provider row later
# matched reads as a document WITH corroboration, never as a competing answer.
class EntryProvenanceTest < ActiveSupport::TestCase
  test "an entry a provider wrote reads as synced" do
    entry = entries(:transaction_entry)
    entry.update!(source: "plaid", external_id: "abc123", import: nil)

    assert_equal "synced", EntryProvenance.for(entry).primary
  end

  test "an entry a file import wrote reads as a file import, even with no source" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import_locked: true)

    assert_equal "import_file", EntryProvenance.for(entry).primary
  end

  test "an entry a document created reads as a document" do
    entry = entries(:transaction_entry)
    entry.update!(source: "document", external_id: "document:#{SecureRandom.uuid}", import: nil)

    assert_equal "document", EntryProvenance.for(entry).primary
  end

  test "a matched document promotes a synced entry rather than competing with it" do
    entry = entries(:transaction_entry)
    entry.update!(source: "plaid", external_id: "abc123")
    link = document_links(:unlinked_receipt)
    link.update!(entry_id: entry.id)

    provenance = EntryProvenance.for(entry.reload)
    assert_equal "document", provenance.primary
    assert_includes provenance.documents.map(&:id), link.id
  end

  test "an entry with nothing attached reads as manual" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: nil, import_locked: false)
    entry.document_links.delete_all

    assert_equal "manual", EntryProvenance.for(entry).primary
  end

  test "an OFX entry reads as a file import from its source alone" do
    entry = entries(:transaction_entry)
    entry.update!(source: "ofx", external_id: "stmt:abc:1", import: nil, import_locked: false)

    assert_equal "import_file", EntryProvenance.for(entry).primary
  end

  test "an entry a real import wrote reads as a file import from its import alone" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: imports(:transaction), import_locked: false)

    assert_equal "import_file", EntryProvenance.for(entry).primary
  end

  test "an entry whose import carries a document reads as a document with no link attached" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: imports(:receipt_understood), import_locked: false)
    entry.document_links.delete_all

    assert_equal "document", EntryProvenance.for(entry.reload).primary
  end

  # The statement route (Milestone A's `route_statement` / PdfImport): every row a
  # statement produced used to read "from a bank export" with no chip back to the
  # document the user uploaded. Task 5's review believed this was covered, but its
  # fixtures only ever exercised a RECEIPT and a CSV import — a statement case
  # never existed. Finding 1's seam: the statement's PdfImport now carries the
  # statement's own archived link.
  test "an entry a statement produced reads as a document, not a bank export" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: statement_backed_import, import_locked: true)
    entry.document_links.delete_all

    provenance = EntryProvenance.for(entry.reload)
    assert_equal "document", provenance.primary
    assert_equal "from a document", provenance.label
    assert_not provenance.corroborated?,
               "a document must never corroborate the entry it created itself"
  end

  test "it never returns anything outside the four" do
    Entry.find_each do |entry|
      assert_includes EntryProvenance::SOURCES, EntryProvenance.for(entry).primary
    end
  end

  # --- documents: the corroborating list, additive and never a second primary ---

  test "a corroborated entry lists its documents and keeps the document primary" do
    entry = entries(:transaction_entry)
    entry.update!(source: "plaid", external_id: "abc123")
    link = document_links(:unlinked_receipt)
    link.update!(entry_id: entry.id)

    provenance = EntryProvenance.for(entry.reload)
    assert_equal [ link.id ], provenance.documents.map(&:id)
    assert_equal "document", provenance.primary
    assert provenance.corroborated?, "a synced row a document later matched is the two-source case"
  end

  test "a receipt whose only origin is its own document is not corroborated" do
    entry = receipt_born_entry

    provenance = EntryProvenance.for(entry)
    assert_equal "document", provenance.primary
    assert_not provenance.corroborated?
  end

  test "a statement claiming a receipt's entry is corroborated" do
    entry = receipt_born_entry
    # The second source: the statement's link, attached when the statement row
    # matches the receipt's entry (Task 7's `claim!`).
    document_links(:unlinked_receipt).update!(entry_id: entry.id)

    provenance = EntryProvenance.for(entry.reload)
    assert_equal "document", provenance.primary
    assert provenance.corroborated?,
           "a receipt matched to a statement row is one transaction with two sources"
  end

  test "an entry with no documents is not corroborated" do
    assert_not EntryProvenance.for(entries(:transaction_entry)).corroborated?
  end

  # --- edited?: the displayed value against what the document actually said ---

  test "an entry whose amount and date still match the read is not edited" do
    assert_not EntryProvenance.for(entry_matching_read(amount: 12, date: Date.new(2026, 9, 14))).edited?
  end

  test "an amount changed after the read reads as edited" do
    assert EntryProvenance.for(entry_matching_read(amount: 42, date: Date.new(2026, 9, 14))).edited?
  end

  test "a date changed after the read reads as edited" do
    assert EntryProvenance.for(entry_matching_read(amount: 12, date: Date.new(2026, 9, 15))).edited?
  end

  test "an unparseable document value is not an edit, and never raises" do
    entry = entries(:transaction_entry)
    document_links(:understood_receipt_link).update!(entry_id: entry.id)
    document_extractions(:understood_receipt_extraction).update!(
      verdict: { "total" => "not a number", "date" => "the fourteenth of never" }
    )

    assert_not EntryProvenance.for(entry.reload).edited?
  end

  test "a non-hash verdict is not an edit, and never raises" do
    entry = entries(:transaction_entry)
    document_links(:understood_receipt_link).update!(entry_id: entry.id)
    document_extractions(:understood_receipt_extraction).update!(verdict: [])

    assert_not EntryProvenance.for(entry.reload).edited?
  end

  test "a document with no read is not an edit" do
    entry = entries(:transaction_entry)
    document_links(:unlinked_receipt).update!(entry_id: entry.id)

    assert_not EntryProvenance.for(entry.reload).edited?
  end

  test "an entry with no document is not edited" do
    assert_not EntryProvenance.for(entries(:transaction_entry)).edited?
  end

  # --- label ---

  test "a document entry's label reads in plain words" do
    entry = entries(:transaction_entry)
    entry.update!(source: "document", external_id: "document:#{SecureRandom.uuid}", import: nil)

    assert_equal "from a document", EntryProvenance.for(entry).label
  end

  test "an import entry's label reads in plain words" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import_locked: true)

    assert_equal "from a bank export", EntryProvenance.for(entry).label
  end

  test "a synced entry's label reads in plain words" do
    entry = entries(:transaction_entry)
    entry.update!(source: "plaid", external_id: "abc123", import: nil)

    assert_equal "synced from your bank", EntryProvenance.for(entry).label
  end

  test "a manual entry's label reads in plain words" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: nil, import_locked: false)
    entry.document_links.delete_all

    assert_equal "entered by you", EntryProvenance.for(entry).label
  end

  private
    # A statement-born PdfImport whose statement carries its own archived
    # document link — exactly the shape the native statement route produces.
    # `archive_document_link!` caches a nil read of the statement's own has_one
    # while it builds the link, so re-read before the import is created against
    # the same object.
    def statement_backed_import
      statement = AccountStatement.create_from_upload!(
        family: families(:dylan_family),
        account: nil,
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf",
                            content: file_fixture("imports/sample_bank_statement.pdf").binread)
      )
      statement.archive_document_link!
      PdfImport.create_from_statement!(statement: statement.reload)
    end

    # A receipt-posted entry: source "document" and a ReceiptImport that hangs
    # off the receipt's own link, which is attached to the entry -- exactly what
    # `ReceiptImport#publish` records.
    def receipt_born_entry
      entry = entries(:transaction_entry)
      receipt_link = document_links(:understood_receipt_link)
      entry.update!(source: "document", external_id: "document:#{receipt_link.id}",
                    import: imports(:receipt_understood))
      receipt_link.update!(entry_id: entry.id)
      entry.reload
    end

    # The entry linked to `understood_receipt_link`, whose latest read says
    # total 12.00 and date 2026-09-14, showing the given amount and date.
    def entry_matching_read(amount:, date:)
      entry = entries(:transaction_entry)
      document_links(:understood_receipt_link).update!(entry_id: entry.id)
      entry.update!(amount: amount, date: date)
      entry.reload
    end
end
