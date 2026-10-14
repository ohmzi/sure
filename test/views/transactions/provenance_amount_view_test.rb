require "test_helper"

# Spec N13, the row. The owner's report: the row named its source document in a
# trailing pill -- "from a document" plus the filename -- and a long filename in
# a `shrink-0` cluster pushed the amount off the row. The row no longer carries
# the provenance fragment; the AMOUNT is the link back to the document that
# CREATED the entry -- `producing_document` (a statement's link, on the import) or
# `creating_document` (a receipt's link, on the import but also attached to the
# entry) -- so both a statement row and a receipt row link to the document they
# came from. A row no document created (a synced or hand-entered row, a raw
# CSV/OFX import, a provider row merely CORROBORATED by a match) renders a plain,
# unlinked amount, and a deleted creating document is not linked either. The
# detail drawer still names every related document.
class Transactions::ProvenanceAmountViewTest < ActionView::TestCase
  test "a statement-born row links its amount to the producing document" do
    entry, document = statement_born_entry

    html = row_html(entry)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "a", amount.name, "the amount itself is the link to the document"
    assert_equal viewer_document_path(document), amount["href"], "the link reuses the viewer route the removed pill used"
    assert_equal "modal", amount["data-turbo-frame"],
                 "the viewer opens as the modal, not inside the row's own turbo frame"
    assert_equal document.original_filename, amount["title"], "the document stays discoverable by name"
    assert_includes amount["aria-label"], ApplicationController.helpers.format_money(-entry.amount_money),
                    "the accessible name still carries the amount (WCAG 2.5.3 label in name)"
    assert_match(/document/, amount["aria-label"],
                 "a bare amount read aloud as a link would tell a screen reader nothing")
  end

  test "a receipt-born row links its amount to its receipt" do
    # A receipt's creating link hangs off the import AND is attached to the entry
    # (its entry_id), so `producing_document` is nil for it -- `creating_document`
    # is what makes the receipt row's amount the link back to its document.
    entry = receipt_born_entry
    link = entry.import.document_link

    html = row_html(entry)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "a", amount.name, "a receipt row's amount is the link to its receipt"
    assert_equal viewer_document_path(link), amount["href"]
    assert_equal link.title.presence || link.original_filename, amount["title"]
    assert_includes amount["aria-label"], link.title.presence || link.original_filename
  end

  test "the row no longer renders the provenance pills" do
    entry, document = statement_born_entry

    html = row_html(entry)

    assert_nil html.at_css("[data-provenance]"), "the row must not carry the provenance fragment"
    refute_includes html.text, I18n.t("entries.provenance.document"), "the row must not say \"from a document\""
    refute_includes html.text, document.original_filename, "the row must not name the filename"
  end

  test "a hand-entered row's amount is not a link" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: nil, import_locked: false)
    entry.document_links.delete_all

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "a manual entry's amount stays a plain amount"
    assert_nil amount["href"]
    assert_nil html.at_css("[data-provenance]")
  end

  test "a synced row's amount is not a link" do
    entry = entries(:transaction_entry)
    entry.update!(source: "plaid", external_id: "plaid-1", import: nil, import_locked: false)
    entry.document_links.delete_all

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "a synced entry's amount stays a plain amount"
    assert_nil amount["href"]
  end

  test "an OFX row's amount is not a link" do
    entry = entries(:transaction_entry)
    entry.update!(source: "ofx", external_id: "stmt:abc:1", import: nil, import_locked: false)
    entry.document_links.delete_all

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "an OFX row has no creating document to link"
    assert_nil amount["href"]
  end

  test "a CSV-import row with no document link is not linked" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: imports(:transaction), import_locked: true)
    entry.document_links.delete_all

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "a raw file import created no document"
    assert_nil amount["href"]
  end

  test "a provider row merely corroborated by a document is not linked" do
    # The whole point of the "no producing document -> no link" rule: a document
    # that later MATCHED a synced row is corroboration, not a source.
    entry = entries(:transaction_entry)
    entry.update!(source: "plaid", external_id: "plaid-2", import: nil, import_locked: false)
    document_links(:unlinked_receipt).update!(entry_id: entry.id)

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "a match is not a source: the amount stays plain"
    assert_nil amount["href"]
  end

  test "a deleted producing document is not linked" do
    entry, document = statement_born_entry
    # A tombstone may only be laid down over a settled (reconciled) entry; the
    # guard is the point of the soft delete, so satisfy it rather than bypass it.
    entry.update!(reconciled_at: Time.current)
    document.soft_delete!

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "a tombstone has left the archive: the amount stays plain"
    assert_nil amount["href"]
  end

  test "a deleted creating document is not linked" do
    # The receipt case: the creating link is attached to the entry, so it may be
    # tombstoned only over a settled entry -- same dead-source pattern.
    entry = receipt_born_entry
    document = entry.import.document_link
    entry.update!(reconciled_at: Time.current)
    document.soft_delete!

    html = row_html(entry.reload)

    amount = html.at_css(".privacy-sensitive")
    assert_equal "p", amount.name, "a tombstoned receipt is not linked"
    assert_nil amount["href"]
  end

  private
    def row_html(entry)
      Nokogiri::HTML.fragment(
        render(partial: "transactions/transaction", locals: { entry: entry, balance_trend: nil, view_ctx: "global" })
      )
    end

    # A statement-born row: a PdfImport carrying the statement's own archived
    # document link, attached to the entry's import -- never to
    # `entry.document_links`, exactly the shape the native statement route makes.
    def statement_born_entry
      statement = AccountStatement.create_from_upload!(
        family: families(:dylan_family),
        account: nil,
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf",
                            content: file_fixture("imports/sample_bank_statement.pdf").binread)
      )
      statement.archive_document_link!
      import = PdfImport.create_from_statement!(statement: statement.reload)
      entry = entries(:transaction_entry)
      entry.update!(source: nil, external_id: nil, import: import, import_locked: true)
      entry.document_links.delete_all
      [ entry.reload, import.document_link ]
    end

    # A receipt-posted row: source "document", a ReceiptImport whose document
    # link is the receipt's own link, attached to the entry (its entry_id) --
    # exactly what `ReceiptImport#publish` records.
    def receipt_born_entry
      entry = entries(:transaction_entry)
      receipt_link = document_links(:understood_receipt_link)
      entry.update!(source: "document", external_id: "document:#{receipt_link.id}",
                    import: imports(:receipt_understood))
      receipt_link.update!(entry_id: entry.id)
      entry.reload
    end
end
