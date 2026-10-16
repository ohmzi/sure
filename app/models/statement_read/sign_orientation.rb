# frozen_string_literal: true

class StatementRead
  # Puts a model's statement rows into the reader's sign convention — credits
  # and payments positive, charges negative — which is what the import's
  # signage expects. A model reads the statement's OWN printed signs (a
  # payment "-500.00"); imported unchanged, every payment would land as an
  # expense and every purchase as income.
  #
  # The statement's printed totals decide when they can: whichever orientation
  # reconciles is the right one, and that is verified. Without totals, the rows
  # whose names say they are credits (a payment, a refund) vote — unverified.
  # With neither, the rows are left as read and the read says so.
  class SignOrientation
    CREDIT_NAME = /\b(PAYMENTS?|CREDITS?|REFUNDS?|RETURNS?)\b/i

    Result = Data.define(:rows, :orientation, :verified)

    def self.call(rows, totals, text: nil) = new(rows, totals, text: text).call

    def initialize(rows, totals, text: nil)
      @rows = Array(rows)
      @totals = totals || {}
      @text = text
    end

    def call
      return Result.new(rows: @rows, orientation: :undecided, verified: false) if @rows.empty?

      flipped = @rows.map { |row| flip(row) }
      as_read_ok = reconciles?(@rows)
      flipped_ok = reconciles?(flipped)
      # Exactly one orientation balancing is proof. Both balancing (credits equal
      # charges — a card paid in full with matching spend) proves nothing, so the
      # credit-named rows decide, unverified.
      return Result.new(rows: @rows, orientation: :as_read, verified: true) if as_read_ok && !flipped_ok
      return Result.new(rows: flipped, orientation: :flipped, verified: true) if flipped_ok && !as_read_ok

      case credit_vote
      when :flip then Result.new(rows: flipped, orientation: :keywords, verified: false)
      when :keep then Result.new(rows: @rows, orientation: :keywords, verified: false)
      else Result.new(rows: @rows, orientation: :undecided, verified: false)
      end
    end

    private
      def reconciles?(rows)
        entries = rows.map { |row| { "date" => row["date"], "amount" => amount(row)&.to_s("F") } }
        return false if entries.any? { |entry| entry["amount"].nil? }

        Reconciliation.call(entries, @totals, text: @text).trusted?
      end

      # Credits are positive in the reader's convention, so credit-named rows
      # printed mostly negative mean the whole read is in the statement's signs.
      def credit_vote
        signs = @rows.select { |row| row["name"].to_s.match?(CREDIT_NAME) }.filter_map { |row| amount(row)&.negative? }
        return nil if signs.empty? || signs.count(true) == signs.count(false)

        signs.count(true) > signs.count(false) ? :flip : :keep
      end

      def flip(row)
        value = amount(row)
        value ? row.merge("amount" => format("%.2f", -value)) : row
      end

      def amount(row)
        BigDecimal(row["amount"].to_s.delete("$, "))
      rescue ArgumentError, TypeError
        nil
      end
  end
end
