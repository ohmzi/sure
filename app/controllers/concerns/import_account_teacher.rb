# frozen_string_literal: true

# Shared by the two controllers where a human sets an import's account:
# Import::AccountsController (the step-3 confirm screen) and ImportsController
# (a statement review screen's inline account select). Both hold the same
# signal — a person has just said which account the document belongs to — so
# both let that account learn its card identity from the read that produced the
# draft (spec N14's learned half).
#
# This is only the derivation of Account#learn_card_identity's two inputs; the
# rule itself, its per-field fill-only guards and its last4 witness gate live on
# the model. The witness is the pipeline's own deterministic check
# (DocumentUnderstandingJob.validate -> document_extractions.validations), so an
# unconfirmed or unwitnessed read can never become durable identity.
module ImportAccountTeacher
  private
    def teach_account(account)
      extraction = @import.document_extraction
      return if extraction.nil?

      account.learn_card_identity(
        DocumentUnderstanding.new(extraction.verdict),
        last4_in_ocr: extraction.validations["last4_in_ocr"]
      )
    end
end
