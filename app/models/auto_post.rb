# frozen_string_literal: true

# The conditions under which a receipt may post itself (spec N6).
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
    !undone? && single_transaction? && resolved? && totals_agree? && class_corroborated?
  end

  private
    # The user already reversed this document's auto-post (spec N6, Task 9's
    # undo). That reversal is DURABLE: the document records it, so a reprocess
    # never silently re-posts money the user took back. The reviewed publish is
    # deliberately untouched -- redoing by hand is still the user's call.
    def undone? = @draft.document_link&.auto_post_undone? == true

    # "Exactly one transaction" — not a batch and not a split. A statement is a
    # batch by definition; a receipt whose line items sum exactly becomes a
    # split (and consequently several entries), which is not one thing to write.
    def single_transaction? = !@draft.line_items_split?

    def resolved? = @draft.total_amount.present? && @draft.purchase_date.present? && @draft.account.present?

    # `true` and only `true`. A nil means the cheap read could not check the
    # total (no labelled total in the OCR text), which is not agreement — it is
    # the absence of the second witness that makes this safe.
    def totals_agree? = @extraction&.validations&.with_indifferent_access&.[]("totals_agree") == true

    # N6's fourth condition (§7.4): the class was CORROBORATED by the
    # deterministic witness, not merely named by the model. `DocumentClassifier`
    # writes this boolean to `document_links`; the gate reads it directly. A nil
    # (a historical row, or any future write path that forgets to set it) reads
    # as NOT corroborated — `true` and only `true`, the strict and safe reading:
    # an unset witness must never post money.
    def class_corroborated? = @draft.document_link&.classification_corroborated == true
end
