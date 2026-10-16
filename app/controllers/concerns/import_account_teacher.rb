# frozen_string_literal: true

# Shared by the controllers where a human sets an import's account:
# Import::AccountsController (the step-3 confirm screen), ImportsController
# (a statement review screen's inline account select) and
# AccountStatementsController (the statement page's picker). All hold the same
# signal — a person has just said which account the document belongs to — so
# all let that account learn its card identity from the read that produced the
# draft (spec N14's learned half).
#
# This is only the derivation of Account#learn_card_identity's inputs; the rule
# itself, its per-field fill-only guards and its NUMBER-SPECIFIC last4 witness
# live on the model. The witness needs the page text, not a bare flag, because
# the read reports two last4 candidates and a model can hallucinate one while
# the other is genuinely on the page — so the OCR text (the same snapshot the
# pipeline persisted) is handed to the model, which stores only a value it can
# find there.
module ImportAccountTeacher
  private
    def teach_account(account, extraction = @import&.document_extraction)
      return if extraction.nil? || extraction.status != "succeeded"

      account.learn_card_identity(
        DocumentUnderstanding.new(extraction.verdict),
        ocr_text: extraction.ocr_text
      )
    end

    # The owner's decision (2026-10-16): a person's pick posts a statement whose
    # rows were proven against its printed totals at once; anything unproven
    # keeps the review step. Returns whether it was published.
    def publish_if_reconciled(import)
      return false unless import.is_a?(PdfImport)

      import.reload
      return false unless import.reconciled_read? && import.publishable?

      import.publish_later
      true
    rescue StandardError => e
      Rails.logger.warn("Auto-publish of import #{import.id} skipped: #{e.class}: #{e.message}")
      false
    end
end
