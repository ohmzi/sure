# frozen_string_literal: true

# A posted statement prints what the account held before its rows: its opening
# balance. The owner's first description of the feature — a statement "adds
# account updates to the account and then the transactions" — so the account's
# EARLIEST statement anchors the account's opening balance, dated just before
# its first row, and the balance then ends at the statements' own closing.
#
# Only where that is unambiguous: a manual account (a provider's sync owns a
# linked account's balance), the earliest statement the account has, a printed
# opening balance, and no entries from anywhere else before it.
class StatementBalanceAnchor
  def self.call(statement) = new(statement).call

  def initialize(statement)
    @statement = statement
    @account = statement&.account
  end

  # True when the opening balance changed.
  def call
    return false unless anchorable?

    @account.set_opening_anchor_balance(balance: @statement.opening_balance, date: anchor_date).changes_made?
  end

  private
    def anchorable?
      @account.present? && @account.manual? && @statement.opening_balance.present? &&
        @statement.period_start_on.present? && earliest? && !foreign_entries_before?
    end

    def earliest?
      @account.account_statements.where.not(id: @statement.id)
              .where(period_start_on: ...@statement.period_start_on).none?
    end

    def statement_entries
      @account.entries.where(import_id: PdfImport.where(account_statement: @statement).select(:id))
    end

    def foreign_entries_before?
      @account.entries.where.not(entryable_type: "Valuation")
              .where(date: ...@statement.period_start_on)
              .where.not(id: statement_entries.select(:id)).exists?
    end

    # Before the statement's first row — a row can carry a transaction date
    # before the period it was posted in — and before the period itself.
    def anchor_date
      [ statement_entries.minimum(:date), @statement.period_start_on ].compact.min - 1.day
    end
end
