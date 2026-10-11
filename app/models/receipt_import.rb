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
end
