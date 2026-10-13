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

  def render? = total.positive?

  # The plain-language breakdown, as [count, key-fragment] pairs. Only the
  # non-zero reasons render; a draft that resolved without an account and a
  # draft that resolved and awaits review are different asks, so they are
  # counted apart.
  def reasons
    [
      [ couldnt_read, "couldnt_read" ],
      [ needs_account, "needs_account" ],
      [ ready, "ready" ]
    ].select { |count, _key| count.positive? }
  end

  def total = @total ||= scope.count
  def couldnt_read = @couldnt_read ||= scope.where.not(failure_message: nil).count

  # A draft that resolved (understood) but carries no account: the tile's
  # "Which account?" state, and the strip's "needs an account".
  def needs_account
    @needs_account ||= scope.where(failure_message: nil)
                            .joins(:receipt_imports)
                            .where(receipt_imports: { account_id: nil })
                            .distinct
                            .count
  end

  # The rest of the scope: a resolved draft with an account, unpublished.
  def ready = total - couldnt_read - needs_account

  private
    def scope = @scope ||= DocumentLink.needs_attention(family)
end
