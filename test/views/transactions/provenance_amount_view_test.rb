require "test_helper"

# Spec N13, the row. The owner's report: the row named its source document in a
# trailing pill -- "from a document" plus the filename -- and a long filename in
# a `shrink-0` cluster pushed the amount off the row. The row no longer carries
# the provenance fragment; the AMOUNT is the link back to the document that
# produced the entry (the detail drawer still names every related document). A
# row with no producing document -- synced or hand-entered -- renders a plain,
# unlinked amount, exactly as before: a merely corroborating document is never a
# link target, and a deleted one is not linked either.
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
end
