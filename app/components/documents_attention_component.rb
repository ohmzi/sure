# frozen_string_literal: true

# The design's "needs you" strip (Milestone B, D5): how many documents are
# waiting on a person, why, and one action that filters the grid to exactly
# those. It renders nothing when the count is zero — an empty banner on every
# visit is noise.
class DocumentsAttentionComponent < ApplicationComponent
  def initialize(family:)
    @family = family
  end

  attr_reader :family

  def render? = total.positive? || pending_imports.positive?

  def title
    return I18n.t("document_browser.attention.title", count: total) if total.positive?

    I18n.t("document_browser.attention.imports_title", count: pending_imports)
  end

  # Imports read from documents but not yet published. They are the other half
  # of "a document was processed": the rows exist, the ledger is waiting.
  def pending_imports
    @pending_imports ||= family.imports
                               .where(status: "pending")
                               .where.not(document_link_id: nil)
                               .count
  end

  # The plain-language breakdown, as [count, key-fragment] pairs. Only the
  # non-zero reasons render; a draft that resolved without an account and a
  # draft that resolved and awaits review are different asks, so they are
  # counted apart.
  def reasons
    [
      [ couldnt_read, "couldnt_read" ],
      [ needs_account, "needs_account" ],
      [ ready, "ready" ],
      [ pending_imports, "imports" ]
    ].select { |count, _key| count.positive? }
  end

  def total = @total ||= scope.count
  def couldnt_read = @couldnt_read ||= scope.where.not(failure_message: nil).count

  # Duplicate GROUPS, not documents: the review list shows one row per group and
  # the viewer shows its copies beside it.
  def duplicates
    @duplicates ||= DocumentLink.duplicate_representative_ids(family).size
  end

  # A resolved draft OR a statement row that arrived with no account: the tile's
  # "Which account?" state, and the strip's "needs an account". The two live in
  # different places (a receipt draft on its import, a statement on its vault
  # row) and a join cannot span them without dropping a row, so they are counted
  # apart and summed. A held row is excluded: "couldn't be read" is its own ask,
  # and it is counted there.
  def needs_account = @needs_account ||= drafts_needing_account + statements_needing_account

  # The rest of the scope: a resolved draft with an account, unpublished.
  def ready = total - couldnt_read - needs_account

  private
    def scope = @scope ||= DocumentLink.needs_attention(family)

    def drafts_needing_account
      scope.where(failure_message: nil)
           .joins(:receipt_imports)
           .where(receipt_imports: { account_id: nil })
           .distinct
           .count
    end

    def statements_needing_account
      scope.where(failure_message: nil, account_statement_id: AccountStatement.unmatched.select(:id))
           .distinct
           .count
    end
end
