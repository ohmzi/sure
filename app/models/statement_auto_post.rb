# frozen_string_literal: true

# The owner's rule (2026-10-16): a statement posts itself when its rows were
# proven against its printed totals AND the card/account number it prints is
# one exactly one account already knows. Anything less waits for the owner — the
# account picker for an unknown or shared number, review for an unproven read.
#
# A duplicate month (the same period for the same number as an earlier
# statement) is flagged for the owner to delete: never posted, never deleted by
# Sure.
class StatementAutoPost
  def self.call(link:) = new(link).call

  def initialize(link)
    @link = link
    @statement = link.account_statement
    @import = @statement && PdfImport.find_by(account_statement: @statement)
  end

  def call
    return :needs_account if @statement.nil? || @import.nil?

    if (original = duplicate_of)
      flag_duplicate(original)
      return :duplicate
    end
    return :unverified unless @import.reconciled_read?

    account = owning_account
    return :needs_account if account.nil?

    return :needs_account unless @import.assign_account!(account)

    @import.reload
    return :needs_account unless @import.publishable?

    @import.publish_later
    :posted
  end

  private
    # Every number the statement prints: its main hint and each card it lists.
    def numbers
      [ @statement.account_last4_hint, *Array(@statement.sanitized_parser_output.to_h["card_last4s"]) ].compact_blank.uniq
    end

    # The one account that knows one of the statement's numbers; nil when none
    # does, or when more than one does (never a guess).
    def owning_account
      return nil if numbers.empty?

      candidates = @statement.family.accounts.visible.select { |account| (account.known_card_last4s & numbers).any? }
      candidates.one? ? candidates.first : nil
    end

    # An earlier statement of this family for the same period and number; a copy
    # the owner deleted no longer counts.
    def duplicate_of
      return nil if numbers.empty? || @statement.period_start_on.nil? || @statement.period_end_on.nil?

      @statement.family.account_statements
                .where.not(id: @statement.id)
                .where(period_start_on: @statement.period_start_on, period_end_on: @statement.period_end_on)
                .where("account_statements.created_at < ?", @statement.created_at)
                .order(:created_at)
                .reject { |other| other.archived_document_link&.deleted? }
                .find { |other| ([ other.account_last4_hint, *Array(other.sanitized_parser_output.to_h["card_last4s"]) ] & numbers).any? }
    end

    def flag_duplicate(original)
      hold = DocumentHold.named("statement_duplicate",
                                message: I18n.t("document_holds.statement_duplicate", file: original.filename))
      # A settled copy is held too: it is waiting on the owner's delete.
      @link.hold_for!(hold, extraction: @link.extraction, from: %w[processing queued unlinked])
    end
end
