require "application_system_test_case"

# Every transaction says where the money came from — or says it was entered by
# hand (spec N13, the owner's second complaint: "each transaction that's listed
# doesn't point to exactly where it came from, so I can't verify"). The resolver
# is Task 5's `EntryProvenance`; this file pins its render on the drawer.
class DocumentProvenanceTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "a transaction from a document says so, and links to it" do
    entry = entries(:transaction_entry)
    link = document_links(:unlinked_receipt)
    link.update!(entry_id: entry.id)
    visit transaction_path(entry)

    assert_text I18n.t("entries.provenance.document")
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.document")
    assert_selector "[data-provenance] a[href='#{viewer_document_path(link)}']"
  end

  # The LIST row, not the drawer (the owner's report): the row named its source
  # document in a trailing pill and a long filename pushed the amount off the
  # row. The amount is now the link, and the row carries no provenance text at
  # all -- the drawer below still names every related document.
  test "on the list, a statement-born row's amount links to its document and the row names none" do
    entry = entries(:transaction_entry)
    statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family),
      account: nil,
      file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf",
                          content: file_fixture("imports/sample_bank_statement.pdf").binread)
    )
    statement.archive_document_link!
    import = PdfImport.create_from_statement!(statement: statement.reload)
    entry.update!(source: nil, external_id: nil, import: import, import_locked: true)
    entry.document_links.delete_all

    visit transactions_path

    within "##{dom_id(entry.reload)}" do
      assert_selector "a[href='#{viewer_document_path(import.document_link)}']"
      assert_no_selector "[data-provenance]", text: I18n.t("entries.provenance.document")
      assert_no_text I18n.t("entries.provenance.document")
    end
  end

  test "a transaction typed by hand says that, and claims no document" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: nil, import_locked: false)
    entry.document_links.delete_all
    visit transaction_path(entry.reload)

    assert_text I18n.t("entries.provenance.manual")

    # Scoped to the provenance fragment, not the whole page: the sidebar always
    # carries a Documents nav link, so an unscoped `a[href*='documents']` would
    # fail (or pass) for a reason that is not the claim under test. A manual
    # entry's fragment shows its own pill and links to no document at all.
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.manual")
    assert_no_selector "[data-provenance] a"
  end

  # Spec N9, the soft delete: the document's bytes are gone, but the entry keeps
  # telling the truth. It still reads "from a document" -- provenance is never
  # silently rewritten to "entered by you" -- and the source is named as gone,
  # with no link, because a tombstone has left the archive.
  test "a deleted source document is still named, but as gone" do
    entry = entries(:transaction_entry)
    link = document_links(:understood_receipt_link)
    link.update!(entry_id: entry.id)
    entry.update!(reconciled_at: Time.current)
    link.soft_delete!

    visit transaction_path(entry.reload)

    title = link.title.presence || link.original_filename
    assert_text I18n.t("entries.provenance.document")
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.source_deleted", name: title)
    assert_no_selector "[data-provenance] a[href='#{viewer_document_path(link)}']",
                       text: title
  end

  test "a value changed after the read is marked as edited" do
    entry = entries(:transaction_entry)
    link = document_links(:understood_receipt_link)
    link.update!(entry_id: entry.id)
    # Start from a value that still MATCHES the read (total "12.00", date
    # 2026-09-14), so the badge's arrival is the edit -- not the fixture's own
    # mismatch. `transaction_entry` defaults to 25, which would make the badge
    # show before any change and pass this test vacuously.
    entry.update!(amount: 12, date: Date.new(2026, 9, 14))

    visit transaction_path(entry.reload)
    assert_no_selector "[data-provenance]", text: I18n.t("entries.provenance.edited")

    entry.update!(amount: 12 + 10)

    visit transaction_path(entry.reload)
    assert_text I18n.t("entries.provenance.edited")
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.edited")
  end
end
