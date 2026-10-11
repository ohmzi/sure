# frozen_string_literal: true

# The receipt/bill draft behind the "Receipt or Bill" wizard option (M7
# decision 2). An STI subtype of Import, so publish/clean/confirm/revert are
# the framework's, and the reviewed publish is the ONLY money writer (D8):
# nothing here or in the OCR path creates an entry.
#
# Signage: receipt parsers emit Sure's own convention (expense-positive) —
# `Import::Row#signed_amount` with signage_convention "inflows_negative" is the
# identity, so the framework's own knob carries the sign and no bespoke
# conversion exists.
class ReceiptImport < Import
  UNDERSTANDING_STATES = %w[awaiting_ocr understood needs_understanding].freeze

  belongs_to :document_link, optional: true

  validates :document_link, presence: true
  validates :understanding_state, inclusion: { in: UNDERSTANDING_STATES }

  # (repaired 2026-10-10, verifier F7) The Interfaces' predicates, defined
  # explicitly: `understanding_state` is a plain string column shared by every
  # `Import` subtype (NULL for all the others), so an enum would be noise.
  # Task 6's job and its tests call all three.
  def awaiting_ocr? = understanding_state == "awaiting_ocr"
  def understood? = understanding_state == "understood"
  def needs_understanding? = understanding_state == "needs_understanding"

  def self.create_from_document_link!(document_link:)
    draft = create!(
      family: document_link.family,
      document_link: document_link,
      status: :pending,
      understanding_state: :awaiting_ocr,
      date_format: document_link.family.date_format,
      signage_convention: "inflows_negative"
    )
    # One of the two sides of the settle race: if the snapshot already exists
    # (the link settled before the draft committed), parse now; otherwise the
    # job waits for the capture job's kick (CaptureContentJob).
    ReceiptImport::UnderstandJob.perform_later(draft.id)
    draft
  end

  # --- extracted data -------------------------------------------------------

  def total_amount = extracted_data&.dig("total").presence&.to_d

  def purchase_date
    raw = extracted_data&.dig("date").presence
    raw && Date.parse(raw)
  rescue Date::Error
    nil
  end

  def payee = extracted_data&.dig("payee").presence

  def line_items = Array(extracted_data&.dig("line_items"))

  # Writes the parse result and (re)builds the item rows. State is decided by
  # the parse, never the other way round, and `understood` needs BOTH the total
  # and the purchase date (repaired 2026-10-10, verifier F8): Entry validates
  # date presence, so a date-less receipt published through Import#publish
  # would die inside import! and flip the draft to `failed`. A date-less parse
  # lands `needs_understanding` and the review screen's manual entry supplies
  # the date (mirroring #apply_manual_details!'s own total-AND-date rule).
  def apply_extraction!(extraction)
    parses_fully = extraction.complete? && extraction.date.present?
    transaction do
      update!(
        extracted_data: extraction.to_extracted_data,
        understanding_state: parses_fully ? :understood : :needs_understanding,
        error: if parses_fully then nil
               elsif extraction.complete? then "no purchase date found"
               else "no labelled total found"
               end
      )
      generate_rows_from_line_items!
    end
  end

  def mark_needs_understanding!(message)
    update!(understanding_state: :needs_understanding, error: message)
  end

  # Rows are rebuilt from scratch each run (the PdfImport#generate_rows_from_
  # extracted_data pattern): insert_all! bypasses AR, so reload before
  # destroying or a stale empty collection deletes nothing and collides on
  # (import_id, source_row_number).
  def generate_rows_from_line_items!
    transaction do
      rows.reload.destroy_all

      items = line_items
      if items.empty?
        update_column(:rows_count, 0)
        return
      end

      currency = account&.currency || family.currency
      inserted = items.each_with_index.map do |item, index|
        {
          import_id: id,
          source_row_number: index + 1,
          date: purchase_date&.strftime(date_format),
          amount: item["amount"].to_s,
          name: item["description"].to_s,
          currency: currency
        }
      end
      Import::Row.insert_all!(inserted)
      update_column(:rows_count, rows.reload.count)
    end
  end

  # The wizard's step 2 creates the draft and the understanding job kicks from
  # both sides of the settle race (Task 6); the receipt's screenshot/bytes live
  # on the DocumentLink.
  def document = document_link

  def requires_csv_workflow? = false

  # The wizard's step 2 stages the bytes on the DocumentLink, so the base
  # `uploaded?` (raw_file_str.present?) is false for a receipt and
  # ImportsController#show would take its non-CSV early return, bouncing every
  # visit to the wizard's finish (import_path(draft)) into the CSV upload
  # screen. The staged link IS the upload — the same override shape
  # PdfImport#uploaded? and SureImport#uploaded? use.
  # (M7 Task 5 deviation, recorded: the plan's file lists assign no task this
  # unblock, and Task 7's Step 5 expects `GET import_path(draft)` to render.)
  def uploaded? = document_link.present?

  # The clean screen edits these two per row; the receipt date is the draft's,
  # not each item's.
  def column_keys = %i[name amount]

  # --- publish gate ---------------------------------------------------------

  def configured?
    total_amount.present?
  end

  # (repaired 2026-10-10, verifier F8) The purchase date is part of the gate:
  # Entry validates date presence, and a date-less publish would otherwise die
  # inside import! and flip the draft to failed. Understanding never marks a
  # date-less receipt `understood` (Task 6), so this term is the belt-and-braces
  # pin on the affordance; import!'s guard below is the enforcement.
  # (Ruling M7-L3, 2026-10-11 close-out) a COMPLETED draft is terminal: it is
  # never publishable again. Without this term the review screen (the very page
  # the app redirects to after publishing) still rendered a publish button for a
  # completed draft, and the user route publish_later (complete -> importing)
  # defeated Import#publish's guard, so a second click silently re-ran the writer
  # and doubled the split children.
  def publishable?
    status != "complete" &&
      account.present? && total_amount.present? && purchase_date.present? &&
      cleaned? && mappings.all?(&:valid?)
  end

  # --- the money writer (D8) ------------------------------------------------
  #
  # The ONLY entry writer in M7, reached only through Import#publish (the
  # reviewed publish button). Identity is the spec's reserved idempotency
  # pattern (§7 errata): external_id "paperless:<docID>" + source "paperless",
  # so a replayed or redelivered publish finds the same entry. Heuristic
  # claiming is OFF: publishing never edits or adopts a user's existing entry —
  # linking a receipt to an existing expense is M3's link-only path.
  def import!
    raise "Account required for a receipt import" unless account.present?
    raise "A receipt needs a total before it can be published" unless total_amount.present?
    # (repaired 2026-10-10, verifier F8) Never let Entry's date-presence
    # validation raise from deep inside the adapter (which would flip the draft
    # to failed after a partial write attempt): refuse here, explicitly.
    raise "A receipt needs a purchase date before it can be published" unless purchase_date.present?
    # (Ruling M7-L3, 2026-10-11 close-out) the writer is REPLAY-SAFE, not just
    # guarded upstream: any route or retry that reaches it twice must not post
    # the money twice. The parent entry is claimed by its external_id
    # (paperless:<docID>), so a replay finds it already present and must skip
    # the split entirely rather than re-minting the children.
    # (Ruling M7-L8, 2026-10-11 close-out) ...and the guard is ATOMIC, not a
    # bare check-then-act: the unlocked `data_committed?` let two CONCURRENT
    # submits both read "not committed" and both run the writer, doubling the
    # split children (2 -> 4 under a forced overlap). The guard and the write
    # now share the draft's row lock, so a double-submit serializes: the loser
    # blocks on the lock, then sees the committed data and returns before the
    # adapter is ever touched.
    with_lock do
      if data_committed?
        Rails.logger.info("ReceiptImport #{id}: publish replayed; the entry already exists - nothing written")
        return
      end

      transaction do
        adapter = Account::ProviderImportAdapter.new(account)
        entry = adapter.import_transaction(
          external_id: "paperless:#{document_link.paperless_document_id}",
          source: "paperless",
          amount: total_amount,
          currency: default_currency, # Import's helper: account&.currency || family.currency
          date: purchase_date,
          name: payee.presence || document_link.title.presence ||
                document_link.original_filename.presence || "Receipt",
          allow_heuristic_matching: false
        )
        # Attach to the import so Import#revert unwinds it (and so the entry is
        # protected from provider syncs like every other import-written entry).
        entry.update!(import: self, import_locked: true)
        split_into_line_items!(entry) if line_items_split?
      end
    end
  end

  # Splits only on an exact sum — the QIF split precedent (Entry#split! itself
  # raises unless the parts sum to the parent). A partial parse is kept on the
  # draft for display and never becomes money.
  def line_items_split?
    rows.reload.count > 1 && rows.sum(&:signed_amount) == total_amount
  end

  # Read-only hint for the review screen: same amount/date on the target
  # account already recorded manually. Never blocks, never claims.
  def duplicate_candidate
    return nil unless account.present? && total_amount.present? && purchase_date.present?

    Account::ProviderImportAdapter.new(account).find_duplicate_transaction(
      date: purchase_date, amount: total_amount, currency: default_currency
    )
  end

  def apply_manual_details!(total: nil, date: nil, payee: nil)
    updated = extracted_data&.deep_dup || {}
    if total.present?
      parsed_total = begin
        BigDecimal(total.to_s.delete(","))
      rescue ArgumentError
        nil
      end
      return false if parsed_total.nil? || !parsed_total.positive?

      updated["total"] = parsed_total.to_s("F")
    end
    if date.present?
      parsed_date = begin
        Date.parse(date.to_s)
      rescue Date::Error
        nil
      end
      return false if parsed_date.nil? || parsed_date > Date.current || parsed_date < Entry.min_supported_date

      updated["date"] = parsed_date.iso8601
    end
    updated["payee"] = payee.to_s if payee.present?

    transaction do
      update!(extracted_data: updated)
      update!(understanding_state: :understood, error: nil) if total_amount.present? && purchase_date.present?
      generate_rows_from_line_items!
    end
    true
  end

  private
    def split_into_line_items!(entry)
      splits = rows.ordered.map do |row|
        {
          name: row.name.presence || payee.presence || "Item",
          amount: row.signed_amount,
          category_id: nil,
          excluded: false
        }
      end
      entry.split!(splits) # children inherit import/import_locked from the parent
    end
end
