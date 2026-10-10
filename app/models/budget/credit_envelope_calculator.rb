# Materializes one CreditEnvelope row per (budget month, credit-card account):
# the YNAB-style payment envelope attached to that card. The envelope's balance
# rises as card spending a spending envelope can cover is moved onto it, and
# falls as cc_payment transfers pay the card down. Card spending a spending
# envelope cannot cover is credit overspending: it grows the card's debt and
# leaves the payment envelope alone, the deliberate cash-vs-credit distinction
# of spec §9.5.
#
# Same shape as Budget::RolloverCalculator: derived state and nothing else,
# recomputed in one forward pass over the (family, owner) budget chain whenever
# a month is bootstrapped or an allocation changes, serialized by a
# transaction-scoped advisory lock. It must be called AFTER
# Budget::RolloverCalculator and never inside the row locks of
# BudgetCategory.move_allocation! -- calling it there would take the advisory
# lock while those rows are held and invert the order every other caller uses
# (the deadlock the note on move_allocation! warns about,
# app/models/budget_category.rb:57-68). Both calculators are reached through
# M4a's single seam, Budget::Recalculate.call(family:, budget:), which fixes
# that order in one place.
class Budget::CreditEnvelopeCalculator
  # Raised -- never a silent 1:1 fallback -- when a chain month's currency has
  # no rate for an entry's currency and date (spec §13). Mirrors
  # Budget::ReadyToAssign::MissingExchangeRate.
  class MissingExchangeRate < StandardError; end

  # A namespace of its own: RolloverCalculator holds 1_920_231_276, so the two
  # calculators can never collide on a lock key even for the same chain.
  LOCK_NAMESPACE = 1_920_231_277

  def initialize(family:, budget:)
    @family = family
    @budget = budget
  end

  # Always returns nil; materializing the rows is the effect.
  def recompute!
    # A family with no credit cards pays one query and never contends -- unless
    # a card left scope, in which case its stale rows must still be cleared.
    return nil if credit_accounts.empty? && !stale_rows?

    CreditEnvelope.transaction do
      lock_chain!
      delete_out_of_scope_rows!
      recompute_chain!
    end
    nil
  end

  private
    attr_reader :family, :budget

    def lock_chain!
      CreditEnvelope.connection.execute(
        CreditEnvelope.sanitize_sql_array(
          [ "SELECT pg_advisory_xact_lock(?, hashtext(?))", LOCK_NAMESPACE, chain_key ]
        )
      )
    end

    # Keyed on the chain, not the single month, because the cumulative figures
    # depend on every earlier month of the chain.
    def chain_key
      "budget_credit_envelope:#{family.id}:#{budget.user_id}"
    end

    # Only initialized budgets take part, exactly as in RolloverCalculator: an
    # unopened month is a gap in the chain, and the carry crosses it untouched.
    def chain
      @chain ||= family.budgets
        .where(user_id: budget.user_id)
        .where.not(budgeted_spending: nil)
        .order(:start_date)
        .to_a
    end

    def recompute_chain!
      updates = []
      now = Time.current
      funded_carry = Hash.new(0)
      paid_carry = Hash.new(0)
      carry_currency = nil

      chain.each do |month|
        # A budget freezes its currency when created; a family that switches
        # currency leaves a break in the chain, so the new unit starts the
        # carry from zero (the rule RolloverCalculator uses).
        if carry_currency.present? && carry_currency != month.currency
          funded_carry = Hash.new(0)
          paid_carry = Hash.new(0)
        end
        carry_currency = month.currency

        funded_this_month, paid_this_month = month_movement(month)

        credit_accounts.each do |account|
          # Round to the column's scale (4) before the compare and the write:
          # a scaling factor like 100/130 leaves a sub-scale product that
          # Postgres rounds on store, so an unrounded compare rewrites the row
          # on every pass.
          funded_amount = (funded_carry[account.id] + funded_this_month[account.id]).round(4)
          payment_amount = (paid_carry[account.id] + paid_this_month[account.id]).round(4)

          existing = existing_rows.dig(month.id, account.id)
          if existing.nil? ||
             existing[:funded_amount] != funded_amount ||
             existing[:payment_amount] != payment_amount
            updates << {
              id: existing&.id || SecureRandom.uuid,
              budget_id: month.id,
              account_id: account.id,
              funded_amount: funded_amount,
              payment_amount: payment_amount,
              currency: month.currency,
              created_at: now,
              updated_at: now
            }
          end

          funded_carry[account.id] = funded_amount
          paid_carry[account.id] = payment_amount
        end
      end

      return if updates.empty?

      # The full attribute set makes the INSERT branch legal (budget_id,
      # account_id, currency are NOT NULL), but only the derived columns may be
      # written on conflict: a concurrent request that changed an allocation
      # between our read and this write must not have it clobbered.
      CreditEnvelope.upsert_all(
        updates,
        unique_by: %i[budget_id account_id],
        update_only: %w[funded_amount payment_amount updated_at]
      )
    end

    # Rows for a card no longer in scope -- disabled, exclude_from_reports set,
    # accountable changed, or moved out of this budget's owner scope -- must
    # not linger: the surface renders every row on the budget, and the Close-out
    # claim is one row per in-scope card and month. With no in-scope cards at
    # all, every row for the chain is out of scope.
    def out_of_scope_rows
      scope = CreditEnvelope.where(budget_id: chain.map(&:id))
      in_scope = credit_accounts.map(&:id)
      in_scope.any? ? scope.where.not(account_id: in_scope) : scope
    end

    def stale_rows?
      out_of_scope_rows.exists?
    end

    def delete_out_of_scope_rows!
      out_of_scope_rows.delete_all
    end

    # => [ { account_id => funded_this_month }, { account_id => paid_this_month } ]
    def month_movement(month)
      range = month.period.date_range
      target_currency = month.currency
      budget_categories = month.budget_categories.to_a
      inheriting_by_parent = budget_categories
        .select(&:inherits_parent_budget?)
        .group_by { |bc| bc.category.parent_id }

      funded = Hash.new(0)
      cash_by_category = Hash.new(0)
      card_by_category = Hash.new { |hash, key| hash[key] = Hash.new(0) }

      spending_rows(range).each do |row|
        amount = converted_amount(row["amount"], row["currency"], row["entry_date"], target_currency)
        if row["credit_card"]
          card_by_category[row["category_id"]][row["account_id"]] += amount
        else
          cash_by_category[row["category_id"]] += amount
        end
      end

      budget_categories.each do |budget_category|
        next if budget_category.inherits_parent_budget?

        category_ids = [ budget_category.category_id,
                         *(inheriting_by_parent[budget_category.category_id] || []).map(&:category_id) ]
        envelope = (budget_category[:budgeted_spending] || 0).to_d + budget_category.rolled_over_amount.to_d
        cash = category_ids.sum { |category_id| cash_by_category[category_id] }

        per_card = Hash.new(0)
        category_ids.each do |category_id|
          card_by_category[category_id].each { |account_id, amount| per_card[account_id] += amount }
        end
        card_total = per_card.values.sum
        next if card_total <= 0

        fundable = [ envelope - cash, 0 ].max
        scale = [ BigDecimal("1"), fundable / card_total ].min
        per_card.each { |account_id, amount| funded[account_id] += amount * scale }
      end

      [ funded, payments_by_account(range, target_currency) ]
    end

    # Positive entries (expenses; a purchase is positive, an inflow negative)
    # whose kind is not budget-excluded. Raw amounts come back with their own
    # currency and date; conversion to the month's currency happens per row in
    # Ruby so a missing rate can fail loud, not silently 1:1.
    def spending_rows(range)
      account_ids = included_accounts.pluck(:id)
      return [] if account_ids.empty?

      # Ruling M4b-L3: the bind hash must follow the heredoc TERMINATOR — a hash
      # opened before the body is lexed as SQL text and Ruby refuses to parse
      # (the repo's own pattern: app/models/vector_store/pgvector.rb:76).
      sql = CreditEnvelope.sanitize_sql_array([ <<~SQL,
        SELECT ae.account_id,
               at.category_id,
               (a.accountable_type = 'CreditCard') AS credit_card,
               ae.amount,
               ae.currency,
               ae.date AS entry_date
        FROM entries ae
        INNER JOIN transactions at ON at.id = ae.entryable_id AND ae.entryable_type = 'Transaction'
        INNER JOIN accounts a ON a.id = ae.account_id
        WHERE ae.account_id IN (:account_ids)
          AND ae.excluded = false
          AND ae.date BETWEEN :start_date AND :end_date
          AND ae.amount > 0
          AND at.kind NOT IN (:kinds)
      SQL
        { start_date: range.begin, end_date: range.end,
          kinds: Transaction::BUDGET_EXCLUDED_KINDS, account_ids: account_ids } ])

      CreditEnvelope.connection.select_all(sql).to_a
    end

    # The card's side of every payment: the inflow leg of a Transfer into the
    # card (a transfer into a liability is a payment), or a provider-imported
    # cc_payment leg with no matched counterpart yet. `excluded = false` keeps
    # parity with spending_rows: an excluded payment must not draw the envelope
    # down.
    def payments_by_account(range, target_currency)
      card_ids = credit_accounts.map(&:id)
      return Hash.new(0) if card_ids.empty?

      # `ae.amount < 0` is the direction guard, and it is load-bearing: money
      # paid INTO a card is the inflow leg, whose amount is negative in Sure's
      # convention (Transfer::Creator builds the inflow as `net_inflow * -1`).
      # Without it the `kind = 'cc_payment'` branch would also match the SOURCE
      # card's own positive outflow leg in a card-to-card transfer — drawing the
      # source card's envelope down for a movement that actually grew its debt.
      # Ruling M4b-L3: bind hash after the heredoc terminator (see spending_rows).
      sql = CreditEnvelope.sanitize_sql_array([ <<~SQL,
        SELECT ae.account_id, ae.amount, ae.currency, ae.date AS entry_date
        FROM entries ae
        INNER JOIN transactions at ON at.id = ae.entryable_id AND ae.entryable_type = 'Transaction'
        LEFT JOIN transfers tr ON tr.inflow_transaction_id = at.id
        WHERE ae.account_id IN (:account_ids)
          AND ae.excluded = false
          AND ae.date BETWEEN :start_date AND :end_date
          AND ae.amount < 0
          AND (tr.id IS NOT NULL OR at.kind = 'cc_payment')
      SQL
        { start_date: range.begin, end_date: range.end, account_ids: card_ids } ])

      CreditEnvelope.connection.select_all(sql).each_with_object(Hash.new(0)) do |row, totals|
        totals[row["account_id"]] +=
          converted_amount(row["amount"], row["currency"], row["entry_date"], target_currency).abs
      end
    end

    # Converts a raw amount into `target_currency`, raising -- never falling
    # back to 1:1 -- when no rate exists, mirroring Budget::ReadyToAssign whose
    # materialized rows carry the same risk (spec §13).
    def converted_amount(amount, currency, date, target_currency)
      return amount.to_d if currency == target_currency

      rate = ExchangeRate.find_or_fetch_rate(from: currency, to: target_currency, date: date)&.rate
      if rate.nil?
        raise MissingExchangeRate,
              "no #{currency}->#{target_currency} rate for #{date}"
      end

      amount.to_d * rate
    end

    def existing_rows
      @existing_rows ||= CreditEnvelope
        .where(budget_id: chain.map(&:id))
        .group_by(&:budget_id)
        .transform_values { |rows| rows.index_by(&:account_id) }
    end

    # A personal budget covers only its owner's accounts; the household budget
    # covers every reportable account, the same scope RolloverCalculator pins
    # for the shared chain.
    def included_accounts
      @included_accounts ||= begin
        scope = family.accounts.visible.included_in_reports
        scope = scope.where(owner_id: budget.user_id) if budget.user_id.present?
        scope
      end
    end

    def credit_accounts
      @credit_accounts ||= included_accounts.where(accountable_type: "CreditCard").order(:name).to_a
    end
end
