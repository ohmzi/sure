# The zero-based pool Sure never had: what actually arrived, minus what the
# chain has already assigned, through the end of this budget's period.
# Derived from posted income entries, not from Sure's typed `expected_income`
# forecast -- which stays informational beside it.
class Budget::ReadyToAssign
  class MissingExchangeRate < StandardError; end

  def initialize(family:, budget:)
    @family = family
    @budget = budget
  end

  # RTA: income through month-end minus assignments through the month.
  def amount
    income - assigned
  end

  # Money that arrived: income-category entries in the period, on
  # family-visible included_in_reports accounts, converted to the budget
  # currency. Transfers of ANY kind never count (they move money the user
  # already has -- funds_movement, cc_payment, loan_payment,
  # investment_contribution), and provider-pending entries never count
  # (the money has not arrived yet; Ruling M4a-L1). A one_time entry DOES
  # count: it is real, categorizable money, excluded only from Sure's
  # median-style analytics. Entries reconciled to a statement are excluded
  # per spec 9.1 -- implemented verbatim; see the plan's assumptions.
  def income
    @income ||= -income_entries.sum { |entry| converted_amount(entry) }
  end

  # Every envelope's assignment through the chain, counted once per envelope.
  def assigned
    @assigned ||= budget_chain.sum(&:assigned_total)
  end

  private
    attr_reader :family, :budget

    def period
      budget.period
    end

    def budget_chain
      family.budgets
        .where(user_id: budget.user_id)
        .where.not(budgeted_spending: nil)
        .where("start_date <= ?", budget.start_date)
    end

    def income_category_ids
      @income_category_ids ||= begin
        statement = family.income_statement(user: budget.user, accounts: account_scope)
        statement.net_category_totals(period: period)
                 .net_income_categories
                 .map { |ct| ct.category.id }
                 .compact
      end
    end

    def account_scope
      scope = family.accounts.included_in_reports
      budget.user_id.present? ? scope.where(owner_id: budget.user_id) : scope
    end

    def income_entries
      Entry
        .joins(:account)
        .where(entryable_type: "Transaction")
        .where(excluded: false)
        .where(reconciled_at: nil)
        .where(date: period.start_date..period.end_date)
        .where(accounts: {
          family_id: family.id,
          status: Account::VISIBLE_STATUSES,
          exclude_from_reports: false
        })
        .then { |rel| restrict_to_budget_accounts(rel) }
        .where(entryable_id: qualifying_transactions.select(:id))
        .select(:amount, :currency, :date)
    end

    def restrict_to_budget_accounts(rel)
      budget.user_id.present? ? rel.where(accounts: { owner_id: budget.user_id }) : rel
    end

    # Ruling M4a-L1 (2026-10-10): spec 9.1's "excluding transfers" is the
    # codebase's own TRANSFER_KINDS (Transaction#transfer? uses exactly it);
    # BUDGET_EXCLUDED_KINDS both under-excludes (loan_payment,
    # investment_contribution would count as assignable income) and
    # over-excludes (one_time is real, categorizable income). Pending entries
    # are excluded too: RTA is money that ARRIVED, matching IncomeStatement's
    # excluding_pending house pattern.
    def qualifying_transactions
      Transaction
        .where(category_id: income_category_ids)
        .where.not(kind: Transaction::TRANSFER_KINDS)
        .excluding_pending
    end

    def converted_amount(entry)
      return entry.amount.to_d if entry.currency == budget.currency

      rate = ExchangeRate.find_or_fetch_rate(
        from: entry.currency, to: budget.currency, date: entry.date
      )&.rate
      if rate.nil?
        raise MissingExchangeRate,
              "no #{entry.currency}->#{budget.currency} rate for #{entry.date}"
      end

      entry.amount.to_d * rate
    end
end
