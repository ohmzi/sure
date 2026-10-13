# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261013120000_backfill_statement_import_document_links")

# W3-9: a statement-backed import created before the OFX `document_link` fix (or
# any PdfImport/OfxImport whose statement archived its link after the import was
# written) carries no document_link, so its rows read `import_file` and the
# statement's document could delete over them (spec N9). The backfill points each
# such import at its statement's own archived link.
class BackfillStatementImportDocumentLinksMigrationTest < ActiveSupport::TestCase
  test "sets the statement's archived link on a statement-backed PdfImport" do
    statement = statement_with_link
    import = imports(:pdf)
    import.update_columns(account_statement_id: statement.id, document_link_id: nil)

    run_migration

    assert_equal statement.archived_document_link.id, import.reload.document_link_id
  end

  test "sets it on a statement-backed OfxImport" do
    statement = statement_with_link
    import = OfxImport.create!(family: families(:dylan_family), account: accounts(:depository))
    import.update_columns(account_statement_id: statement.id, document_link_id: nil)

    run_migration

    assert_equal statement.archived_document_link.id, import.reload.document_link_id
  end

  test "never overwrites a document_link that is already set" do
    statement = statement_with_link
    existing = document_links(:unlinked_receipt)
    import = imports(:pdf)
    import.update_columns(account_statement_id: statement.id, document_link_id: existing.id)

    run_migration

    assert_equal existing.id, import.reload.document_link_id
  end

  test "leaves a statement-backed import whose statement has no archived link untouched" do
    statement = statement_without_link
    import = imports(:pdf)
    import.update_columns(account_statement_id: statement.id, document_link_id: nil)

    run_migration

    assert_nil import.reload.document_link_id
  end

  test "does not touch an import type outside PdfImport/OfxImport" do
    statement = statement_with_link
    import = imports(:sure)
    import.update_columns(account_statement_id: statement.id, document_link_id: nil)

    run_migration

    assert_nil import.reload.document_link_id,
               "a non-statement-backed import type must not be backfilled"
  end

  test "is a no-op on an empty set and can be run again" do
    assert_nothing_raised { run_migration }
    assert_nothing_raised { run_migration }
  end

  private
    def run_migration
      ActiveRecord::Migration.suppress_messages do
        BackfillStatementImportDocumentLinks.new.up
      end
    end

    def statement_with_link
      statement = new_statement
      statement.archive_document_link!
      statement.reload
    end

    def statement_without_link
      new_statement
    end

    def new_statement
      AccountStatement.create_from_upload!(
        family: families(:dylan_family),
        account: nil,
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf",
                            content: file_fixture("imports/sample_bank_statement.pdf").binread)
      )
    end
end
