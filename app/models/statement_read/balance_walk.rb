# frozen_string_literal: true

class StatementRead
  # Signs a chequing statement's rows from its running balance. The text layer
  # keeps the amounts but not reliably which column they sat in; the balance
  # they moved does. Each printed balance closes a group of rows (the rows since
  # the last printed balance), and the group's signs are the assignment that
  # moves the balance by exactly the printed difference. A trailing group closes
  # against the statement's closing balance.
  #
  # When more than one assignment fits (two equal amounts that cancel), the
  # group is never guessed — the walk is unverified. A printed column is layout,
  # not proof: with both orientations summing to the same totals, nothing
  # downstream could catch a wrong column (review I1).
  class BalanceWalk
    MAX_GROUP = 16

    # `ambiguities` carries each group the balance alone could not orient: its
    # rows, the index of the first one in `rows`, and every candidate sign
    # assignment. The layout may settle one against the statement's printed
    # totals — the balance cannot, but the totals can (RbcChequing does).
    Result = Data.define(:rows, :verified, :ambiguous_groups, :ambiguities)

    def self.call(opening:, closing:, rows:) = new(opening:, closing:, rows:).call

    def initialize(opening:, closing:, rows:)
      @balance = opening
      @closing = closing
      @rows = rows
    end

    def call
      signed = []
      ambiguous = 0
      unfit = false
      group = []
      ambiguities = []

      close_group = lambda do |target|
        signs = assignments(group, target - @balance)
        if signs.size == 1
          group.zip(signs.first).each { |row, sign| signed << row.merge("signed" => sign * row["amount"]) }
        else
          signs.empty? ? unfit = true : ambiguous += 1
          start = signed.length
          group.each { |row| signed << row.merge("signed" => nil) }
          ambiguities << { start: start, group: group.dup, candidates: signs } if signs.size > 1
        end
        @balance = target
        group = []
      end

      @rows.each do |row|
        group << row
        close_group.call(row["balance"]) if row["balance"]
      end
      close_group.call(@closing) if group.any? && @closing

      Result.new(rows: signed, verified: !unfit && ambiguous.zero? && signed.all? { |row| row["signed"] },
                 ambiguous_groups: ambiguous, ambiguities: ambiguities)
    end

    private
      # Every +/- assignment of the group's amounts that sums to the delta.
      def assignments(group, delta)
        return [] if group.empty? || group.size > MAX_GROUP

        [ 1, -1 ].repeated_permutation(group.size).select do |signs|
          group.zip(signs).sum { |row, sign| sign * row["amount"] } == delta
        end
      end
  end
end
