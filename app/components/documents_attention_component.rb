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

  # Every ask renders the strip, including the ones the documents grid cannot
  # list: a duplicate group, a pending import, or a statement-only ask (the
  # PDF-import path mints statements with no DocumentLink).
  def render? = total.positive? || duplicates.positive? || pending_imports.positive?

  def title
    return I18n.t("document_browser.attention.title", count: total) if total.positive?
    return I18n.t("document_browser.attention.imports_title", count: pending_imports) if pending_imports.positive?

    I18n.t("document_browser.attention.duplicates_title", count: duplicates)
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
  # non-zero reasons render. Each reason has a list surface that contains
  # exactly the rows counted: the documents grid for link-backed asks, the
  # vault's q[attention] filter for statements, and the imports page. The
  # draft ask and the unmatched-statement ask are counted apart because a
  # single count cannot point at both surfaces honestly.
  def reasons
    [
      [ couldnt_read, "couldnt_read" ],
      [ needs_account, "needs_account" ],
      [ unmatched_statements, "unmatched" ],
      [ missing_period, "missing_period" ],
      [ missing_printed_identity, "missing_identity" ],
      [ ready, "ready" ],
      [ pending_imports, "imports" ]
    ].select { |count, _key| count.positive? }
  end

  # Every row waiting on a person. The documents grid lists the link-backed
  # ones; a statement with no live document link (the PDF-import path) is
  # added on top. A linked statement is already one of the grid's documents,
  # so it is never counted twice.
  def total = @total ||= document_attention + unlinked_statement_attention

  # What the documents "Show them" filter can list. Kept separate from total so
  # a statement-only ask never points at an empty documents grid.
  def document_attention = @document_attention ||= scope.count
  def couldnt_read = @couldnt_read ||= scope.where.not(failure_message: nil).count

  # Duplicate GROUPS, not documents: the review list shows one row per group and
  # the viewer shows its copies beside it.
  def duplicates
    @duplicates ||= DocumentLink.duplicate_representative_ids(family).size
  end

  # A resolved draft that arrived with no account: the tile's "Which account?"
  # state, and a link-backed document the grid lists. Unmatched STATEMENTS are
  # counted separately (statements can exist with no document link at all, and
  # they have their own vault list). A held row is excluded: "couldn't be read"
  # is its own ask, and it is counted there.
  def needs_account = @needs_account ||= drafts_needing_account

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

    # Statements that need a person but have no live document link. The four
    # attention scopes are disjoint by precedence, so their counts add up
    # without double counting.
    def unlinked_statement_attention
      @unlinked_statement_attention ||=
        AccountStatement::ATTENTION_REASONS.sum do |reason|
          statement_attention_count(reason, unlinked_only: true)
        end
    end

    def statement_attention_count(reason, unlinked_only: false)
      relation = AccountStatement.attention_scope(reason, family: family)
      relation = relation.visible_to(user) if user
      relation = relation.where.not(id: live_statement_link_ids) if unlinked_only
      relation.count
    end

    # The statement's live archival copy (`AccountStatement#archived_document_link`
    # in SQL). A statement absent from this set cannot appear on the documents
    # grid, so it is the statement-only population.
    def live_statement_link_ids
      DocumentLink.where(family: family, source: "statement", deleted_at: nil)
                  .where.not(account_statement_id: nil)
                  .select(:account_statement_id)
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
