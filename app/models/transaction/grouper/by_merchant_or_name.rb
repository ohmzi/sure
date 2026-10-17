class Transaction::Grouper::ByMerchantOrName < Transaction::Grouper
  def self.call(entries, limit: 20, offset: 0)
    new(entries).call(limit: limit, offset: offset)
  end

  # The signal a transaction speaks: its merchant (when detected) or its
  # name, plus whether the money went out or came in. Exposed so a single
  # transaction can ask for the other uncategorized rows that share it.
  def self.grouping_key_for(entry)
    name = entry.entryable.merchant&.name.presence || entry.name
    type = entry.amount.negative? ? "income" : "expense"
    [ name, type ]
  end

  # Whether two rows are similar enough for a category chosen on one to fit
  # the other: same cash-flow direction, and either the same detected
  # merchant or the same description. Checking both matters because one row
  # may have a merchant detected while its siblings only carry the raw
  # statement text.
  def self.similar?(left, right)
    left_merchant, left_name, left_type = similar_key_for(left)
    right_merchant, right_name, right_type = similar_key_for(right)

    left_type == right_type &&
      ((left_merchant.present? && left_merchant == right_merchant) || left_name == right_name)
  end

  def self.similar_key_for(entry)
    [
      entry.entryable.merchant&.name.presence,
      entry.name,
      entry.amount.negative? ? "income" : "expense"
    ]
  end

  def initialize(entries)
    @entries = entries
  end

  def call(limit: 20, offset: 0)
    uncategorized_entries
      .group_by { |entry| grouping_key_for(entry) }
      .map { |key, entries| build_group(key, entries) }
      .sort_by { |g| [ -g.entries.size, g.display_name ] }
      .drop([ offset, 0 ].max)
      .first(limit)
  end

  private

    attr_reader :entries

    def uncategorized_entries
      entries
        .uncategorized_transactions
        .includes(entryable: :merchant)
        .order(entries: { date: :desc })
    end

    def grouping_key_for(entry)
      self.class.grouping_key_for(entry)
    end

    def build_group(key, entries)
      name, type = key
      merchant = entries.find { |e| e.entryable.merchant.present? }&.entryable&.merchant

      Transaction::Grouper::Group.new(
        grouping_key: name,
        display_name: name,
        entries: entries,
        merchant: merchant,
        transaction_type: type
      )
    end
end
