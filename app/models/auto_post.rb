# frozen_string_literal: true

# The four conditions under which a receipt may post itself (spec N6).
#
# A pure decision, deliberately not a condition inside a job: this is the only
# place the program writes money without a human clicking, so it must be
# testable on its own and readable in one screen.
class AutoPost
  def self.allowed?(draft:, extraction:)
    new(draft:, extraction:).allowed?
  end

  def initialize(draft:, extraction:)
    @draft = draft
    @extraction = extraction
  end

  def allowed?
    single_transaction? && resolved? && totals_agree? && class_corroborated?
  end

  private
    # "Exactly one transaction" — not a batch and not a split. A statement is a
    # batch by definition; a receipt whose line items sum exactly becomes a
    # split (and consequently several entries), which is not one thing to write.
    def single_transaction? = !@draft.line_items_split?

    def resolved? = @draft.total_amount.present? && @draft.purchase_date.present? && @draft.account.present?

    # `true` and only `true`. A nil means the cheap read could not check the
    # total (no labelled total in the OCR text), which is not agreement — it is
    # the absence of the second witness that makes this safe.
    def totals_agree? = @extraction&.validations&.with_indifferent_access&.[]("totals_agree") == true

    # `classified_by == "ai"` is the persisted form of "the classifier accepted
    # this class" — `DocumentClassifier` writes "ai" only when it either
    # corroborated the class or found it confidently asserted, and "fallback"
    # otherwise. There is no separate `corroborated` column and this task does
    # not add one.
    def class_corroborated? = @draft.document_link&.classified_by == "ai"
end
