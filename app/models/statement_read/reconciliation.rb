# frozen_string_literal: true

class StatementRead
  # The gate. A read's rows are proven against the statement's OWN printed
  # arithmetic before anyone may trust them (§3). Each check is a WITNESS:
  #
  #   * `+`     — applicable and passed;
  #   * `drift` — applicable and failed (the read contradicts the statement);
  #   * `skip`  — the statement printed no figure to check against (never a pass).
  #
  # Checks:
  #   C1 row_parse         every row has a date and an amount, no missing-date row,
  #                        no line rejected after the drill-down stop.
  #   C2 credits_sum       Σ(credit rows) == |Total credits|
  #   C3 purchases_sum     Σ(purchases rows) == |Total purchases|
  #   C4 charges_identity  purchases + cash + fees + interest == |Total charges|
  #   C5 balance_identity  opening + |Total charges| − |Total credits| == new balance
  #   C6 card_<last4>      Σ(rows for card) == |Total purchases for <card>|
  #   C7 row_count,row_sanity  a stated count equals the row count (when printed);
  #                        ≥1 row and no row equal to the statement's own balance.
  #
  # Sign: the reader's rows use the ROW convention (credits positive, charges
  # negative), so it compares its buckets to the MAGNITUDE of the statement's
  # stated totals (which are printed credit-negative).
  #
  # The reader has no section (a vision row) falls back to the printed sign for
  # its credit/charge buckets, and the section-keyed checks (C3, C6) skip.
  class Reconciliation
    PASS = "+"
    DRIFT = "drift"
    SKIP = "skip"
    STRONG = %w[credits_sum purchases_sum charges_identity balance_identity].freeze

    Result = Data.define(:verdict, :checks, :deltas, :figures, :rounding_delta) do
      def trusted? = verdict == :trusted
    end

    def self.call(entries, totals, text: nil, missing_date_rows: [], rejected_lines: [])
      new(entries, totals, text: text, missing_date_rows: missing_date_rows,
          rejected_lines: rejected_lines).call
    end

    def initialize(entries, totals, text: nil, missing_date_rows: [], rejected_lines: [])
      @entries = Array(entries)
      @totals = totals || {}
      @text = text
      @missing = Array(missing_date_rows)
      @rejected = Array(rejected_lines)
      @checks = {}
      @deltas = {}
      @figures = {}
    end

    def call
      sectioned = @entries.any? { |entry| entry["section"].present? }
      sums = bucket_sums(@entries)

      # C1 — a date-led line we could not build, a dateless amount, or a row
      # seen after the drill-down stop: the read is not a clean parse.
      rows_ok = @missing.empty? && @rejected.empty? &&
                @entries.all? { |entry| entry["date"].present? && entry["amount"].present? }
      @checks["row_parse"] = if @entries.empty?
        SKIP
      else
        rows_ok ? PASS : DRIFT
      end

      # C2/C3/C4 — the buckets. Section-keyed buckets fall to the printed sign
      # for a read with no sections (C3 then skips).
      add("credits_sum", credit_bucket(sums, sectioned), @totals["total_credits"])
      add("purchases_sum", sectioned ? sums[:purchases] : nil, @totals["purchases"])
      add("charges_identity", charge_bucket(sums, sectioned), @totals["total_charges"])

      # C5 — the balance identity, over the statement's own figures.
      opening = @totals["opening"]
      charges = @totals["total_charges"]
      credits = @totals["total_credits"]
      new_balance = @totals["new_balance"]
      if [ opening, charges, credits, new_balance ].all?
        add("balance_identity", opening + charges.abs - credits.abs, new_balance)
      else
        @checks["balance_identity"] = SKIP
      end

      per_card_checks(sums, sectioned)
      count_check
      @checks["row_sanity"] = row_sanity

      Result.new(verdict: verdict, checks: @checks, deltas: @deltas, figures: @figures,
                 rounding_delta: rounding_delta)
    end

    private
      def bucket_sums(entries)
        sums = Hash.new(BigDecimal(0))
        entries.each do |entry|
          section = entry["section"]
          sums[section] += entry["amount"].to_d.abs if section
        end
        sums
      end

      def credit_bucket(sums, sectioned)
        return sums[:payments] + sums[:returns] if sectioned

        @entries.sum(BigDecimal(0)) { |entry| [ entry["amount"].to_d, BigDecimal(0) ].max }
      end

      def charge_bucket(sums, sectioned)
        return sums[:purchases] + sums[:cash] + sums[:fees] + sums[:interest] if sectioned

        @entries.sum(BigDecimal(0)) { |entry| [ -entry["amount"].to_d, BigDecimal(0) ].max }
      end

      # C6 — a per-card subtotal catches a row dropped mid-section even when the
      # grand total would still hold.
      def per_card_checks(sums, sectioned)
        cards = @totals["cards"] || {}
        if sectioned && cards.any?
          card_sums = Hash.new(BigDecimal(0))
          @entries.each do |entry|
            card_sums[entry["card"]] += entry["amount"].to_d.abs if entry["section"] == :purchases && entry["card"]
          end
          cards.each { |card, stated| add("card_#{card}", card_sums[card], stated) }
        else
          cards.each_key { |card| @checks["card_#{card}"] = SKIP }
        end
      end

      def count_check
        count = @totals["transaction_count"]
        @checks["row_count"] = count.nil? ? SKIP : (@entries.size == count ? PASS : DRIFT)
      end

      def row_sanity
        return SKIP if @entries.empty?

        balance = @totals["new_balance"]
        return PASS if balance.nil?

        clash = @entries.any? { |entry| (entry["amount"].to_d.abs - balance.to_d.abs).abs <= StatementRead::ROUNDING_BAND }
        clash ? DRIFT : PASS
      end

      # One check, present whenever the statement printed the figure to check it
      # against. `nil` (skipped) is never a pass and never a fail.
      def add(name, read, stated)
        if stated.nil? || read.nil?
          @checks[name] = SKIP
          return
        end

        read_mag = read.to_d.abs
        stated_mag = stated.to_d.abs
        delta = read_mag - stated_mag
        @checks[name] = delta.abs <= StatementRead::ROUNDING_BAND ? PASS : DRIFT
        @figures[name] = { read: read_mag, stated: stated_mag }
        @deltas[name] = delta
      end

      def verdict
        return :empty_but_expected if @entries.empty? && totals_expect_money?
        return :drift if @checks.value?(DRIFT)
        return :trusted if trusted?

        :unreconcilable
      end

      def trusted?
        return false if @entries.empty?
        return false if @missing.any? || @rejected.any?
        return false if @checks.value?(DRIFT)

        @checks.any? { |name, state| state == PASS && strong?(name) }
      end

      def strong?(name) = STRONG.include?(name) || name.start_with?("card_")

      def totals_expect_money?
        %w[total_credits total_charges purchases new_balance].any? do |key|
          (value = @totals[key]) && value.to_d.abs.positive?
        end
      end

      # The largest residual a passing check absorbed inside the rounding band —
      # recorded on the verdict, never hidden. Zero when money is exact.
      def rounding_delta
        @deltas.select { |name, _| @checks[name] == PASS }.values.map { |delta| delta.to_d.abs }.max ||
          BigDecimal(0)
      end
  end
end
