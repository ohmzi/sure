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
    create!(
      family: document_link.family,
      document_link: document_link,
      status: :pending,
      understanding_state: :awaiting_ocr,
      date_format: document_link.family.date_format,
      signage_convention: "inflows_negative"
    )
  end

  # The wizard's step 2 creates the draft and the understanding job is kicked
  # by Task 6; the receipt's screenshot/bytes live on the DocumentLink.
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
