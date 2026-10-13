# frozen_string_literal: true

# W3-9: backfill `document_link` on statement-backed imports written before the
# fix that sets it at creation time (and on any PdfImport/OfxImport whose
# statement archived its document link after the import row was written).
#
# A statement's rows hang off `entries.import_id -> imports.document_link_id`
# (spec §8.6, the N13 taxonomy). Without that link a row reads "from a bank
# export" instead of "from a document" (EntryProvenance), and
# DocumentLink#derived_entries cannot see the row -- so the statement's own
# document would delete while its rows were still unreconciled (spec N9). The
# producing document for such an import is the statement's archived copy
# (`account_statements -> document_links` where `source = 'statement'`).
#
# Idempotent and safe on the live DB: it writes only a NULL link, only for rows
# whose statement actually has an archived link, and only for the two
# statement-backed import types (PdfImport, OfxImport) -- a receipt or CSV
# import carries its own link or has none to add. It touches no money column,
# and deliberately leaves `updated_at` alone so no import-lifecycle clock (the
# stuck-import reaper) is disturbed. On an empty matching set it is a no-op.
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
        AND imports.type IN ('PdfImport', 'OfxImport')
    SQL
  end

  def down
    # Not reversible: a backfilled NULL is indistinguishable from a link that was
    # legitimately cleared afterwards, so there is no honest way to unpick it.
    raise ActiveRecord::IrreversibleMigration
  end
end
