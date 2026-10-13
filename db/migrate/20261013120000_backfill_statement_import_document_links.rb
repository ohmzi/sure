# frozen_string_literal: true

# W3-9: backfill `document_link` on statement-backed PdfImports written before
# the fix that sets it at creation time (and on any PdfImport whose statement
# archived its document link after the import row was written).
#
# A statement's rows hang off `entries.import_id -> imports.document_link_id`
# (spec §8.6, the N13 taxonomy). Without that link a PdfImport's row reads "from
# a bank export" instead of "from a document" (EntryProvenance). The producing
# document for such an import is the statement's archived copy
# (`account_statements -> document_links` where `source = 'statement'`).
#
# Deliberately PdfImport ONLY (R-W3B1). An OFX/QFX import must NOT carry a
# document_link -- an OFX bank export is an "Import file", not a "Document"
# (spec §8.6), so its rows read "from a bank export". Its N9 delete-block is
# reached through the statement's id (DocumentLink#derived_entries), not through
# a link on the import.
#
# Idempotent and safe on the live DB: it writes only a NULL link, only for rows
# whose statement actually has an archived link, and only for PdfImports -- a
# receipt or CSV import carries its own link or has none to add. It touches no
# money column, and deliberately leaves `updated_at` alone so no import-lifecycle
# clock (the stuck-import reaper) is disturbed. On an empty matching set it is a
# no-op.
class BackfillStatementImportDocumentLinks < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE imports
      SET document_link_id = links.document_link_id
      FROM (
        SELECT DISTINCT ON (account_statement_id)
               id AS document_link_id, account_statement_id
        FROM document_links
        WHERE source = 'statement' AND account_statement_id IS NOT NULL
        ORDER BY account_statement_id, created_at ASC, id ASC
      ) AS links
      WHERE imports.account_statement_id = links.account_statement_id
        AND imports.document_link_id IS NULL
        AND imports.type = 'PdfImport'
    SQL
  end

  def down
    # Not reversible: a backfilled NULL is indistinguishable from a link that was
    # legitimately cleared afterwards, so there is no honest way to unpick it.
    raise ActiveRecord::IrreversibleMigration
  end
end
