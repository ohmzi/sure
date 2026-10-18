# frozen_string_literal: true

# The design's "needs you" strip (Milestone B, D5): how many documents are
# waiting on a person, why, and one action that filters the grid to exactly
# those. It renders nothing when the count is zero — an empty banner on every
# visit is noise.
class DocumentsAttentionComponent < ApplicationComponent
  def initialize(family:, user: Current.user)
    @family = family
    @user = user
  end

  attr_reader :family, :user

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
      [ missing_period, "missing_period" ],
      [ missing_printed_identity, "missing_identity" ],
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
  def needs_account = @needs_account ||= drafts_needing_account + unmatched_statements

  # P1.11 statement asks. Every one is the SAME relation the vault's q[attention]
  # filter renders, so each count equals the list its button opens. They are
  # disjoint by shared precedence: held, then unmatched, then missing period,
  # then missing identity.
  def held_or_failed = @held_or_failed ||= statement_attention_count("held_or_failed")
  def unmatched_statements = @unmatched_statements ||= statement_attention_count("unmatched")
  def missing_period = @missing_period ||= statement_attention_count("missing_period")
  def missing_printed_identity = @missing_printed_identity ||= statement_attention_count("missing_identity")

  # A resolved draft with an account, unpublished. Counted from the document
  # scope directly (not by subtracting statement asks, which are a different
  # population).
  def ready
    @ready ||= scope.where(failure_message: nil)
                    .where(id: ready_draft_links)
                    .where.not(id: drafts_needing_account_links)
                    .count
  end

  private
    def scope = @scope ||= DocumentLink.needs_attention(family)

    def statement_attention_count(reason)
      relation = AccountStatement.attention_scope(reason, family: family)
      relation = relation.visible_to(user) if user
      relation.count
    end

    def ready_draft_links
      ReceiptImport.where(family: family, understanding_state: "understood")
                   .where.not(status: "complete")
                   .select(:document_link_id)
    end

    def drafts_needing_account_links
      ready_draft_links.where(account_id: nil)
    end

    def drafts_needing_account
      scope.where(failure_message: nil)
           .where(id: drafts_needing_account_links)
           .count
    end
end
