require "digest/sha2"

# Imports an OFX/QFX statement. Mirrors QifImport's structure (fixed format,
# no CSV column mapping, ISO dates after parsing) but takes a transaction
# account up front — the OFX upload UI selects one — and writes entries with
# `source: "ofx"` + a `stmt:<fileSha>:<row>` external_id so a re-import is
# idempotent at the database level as well as through the adapter's
# duplicate heuristic.
class OfxImport < Import
  after_create :set_default_config

  # Parses the stored OFX content and creates Import::Row records.
  # Overrides the base CSV-based method with OFX-specific parsing.
  def generate_rows_from_csv
    rows.reload.destroy_all

    mapped_rows = Ofx::Parser.parse(raw_file_str).map.with_index(1) do |trn, index|
      {
        source_row_number:       index,
        date:                    trn.date.to_s,
        amount:                  trn.amount.to_s("F"),  # "F" = plain decimal; bare #to_s emits engineering notation ("-0.4599e2")
        currency:                default_currency.to_s,
        name:                    (trn.payee.presence || default_row_name).to_s,
        notes:                   trn.memo.to_s,
        category:                "",
        tags:                    "",
        account:                 "",
        qty:                     "",
        ticker:                  "",
        price:                   "",
        exchange_operating_mic:  "",
        entity_type:             trn.fitid.to_s,
        resource_type:           ""
      }
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
    rows.reset
    update_column(:rows_count, rows.count)
  end

  def import!
    raise "Account required for OFX import" unless account.present?

    transaction do
      adapter = Account::ProviderImportAdapter.new(account)
      claimed = Set.new
      new_transactions = []

      rows.ordered.each do |row|
        external_id = external_id_for(row)

        # This exact file/row was already imported: never re-add it.
        next if account.entries.exists?(source: "ofx", external_id: external_id)

        # A transaction the account already holds (manual entry or a provider
        # sync): claim nothing, create nothing. Name is deliberately excluded
        # from the match for the same reason PdfImport excludes it.
        if (existing = adapter.find_duplicate_transaction(
              date: row.date_iso,
              amount: row.signed_amount,
              currency: row.currency,
              exclude_entry_ids: claimed,
              include_provider_entries: true))
          claimed << existing.id
          next
        end

        new_transactions << Transaction.new(
          entry: Entry.new(
            account:       account,
            date:          row.date_iso,
            amount:        row.signed_amount,
            name:          row.name,
            currency:      row.currency,
            notes:         row.notes,
            import:        self,
            import_locked: true,
            source:        "ofx",
            external_id:   external_id
          )
        )
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  # OFX has a fixed format — no CSV column mapping step needed.
  def requires_csv_workflow?
    false
  end

  def column_keys
    %i[date amount name currency notes]
  end

  # OFX transactions carry no category or tag, so no mapping step is offered.
  def mapping_steps
    []
  end

  def publishable?
    account.present? && super
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    account.present? && super
  end

  def rows_ordered
    rows.ordered
  end

  def content_sha256
    @content_sha256 ||= Digest::SHA256.hexdigest(raw_file_str.to_s)
  end

  def external_id_for(row)
    "stmt:#{content_sha256}:#{row.source_row_number}"
  end

  private

    def set_default_config
      update!(
        signage_convention: "inflows_positive",
        date_format:        "%Y-%m-%d",
        number_format:      "1,234.56"
      )
    end
end
