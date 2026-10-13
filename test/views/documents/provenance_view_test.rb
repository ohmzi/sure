require "test_helper"

# Where this entry came from (spec N13), rendered. A statement-born row reads
# "from a document" but its creating document hangs off the import, not
# `entry.document_links`, so the corroboration loop rendered no chip. W3-7: the
# producing document is rendered as the source chip too, and it is never
# mistaken for a document corroborating the entry it created.
module Documents
  class ProvenanceViewTest < ActionView::TestCase
    test "a statement-born entry renders a chip linking its producing document" do
      import = statement_backed_import
      entry = entries(:transaction_entry)
      entry.update!(source: nil, external_id: nil, import: import, import_locked: true)
      entry.document_links.delete_all

      html = render(partial: "documents/provenance", locals: { entry: entry.reload })

      assert_includes html, I18n.t("entries.provenance.document")
      assert_includes html, viewer_document_path(import.document_link),
                      "the producing document must render as a link back to itself"
    end

    test "a receipt-born entry renders its producing document exactly once" do
      entry = receipt_born_entry

      html = render(partial: "documents/provenance", locals: { entry: entry })

      href = viewer_document_path(entry.import.document_link)
      assert_equal 1, html.scan("href=\"#{href}\"").size,
                   "a document that both produced the entry and is attached to it must render one chip"
    end

    test "a manual entry links to no document" do
      entry = entries(:transaction_entry)
      entry.update!(source: nil, external_id: nil, import: nil, import_locked: false)
      entry.document_links.delete_all

      html = render(partial: "documents/provenance", locals: { entry: entry.reload })

      assert_includes html, I18n.t("entries.provenance.manual")
      assert_not_includes html, "viewer_document_path", "a manual entry must link to no document"
      assert_no_match(/href="[^"]*documents/, html)
    end

    private
      # A statement-born PdfImport whose statement carries its own archived
      # document link -- exactly the shape the native statement route produces.
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

      # A receipt-posted entry: the receipt's own link is both the import's
      # document_link and attached to the entry.
      def receipt_born_entry
        entry = entries(:transaction_entry)
        receipt_link = document_links(:understood_receipt_link)
        entry.update!(source: "document", external_id: "document:#{receipt_link.id}",
                      import: imports(:receipt_understood))
        receipt_link.update!(entry_id: entry.id)
        entry.reload
      end
  end
end
