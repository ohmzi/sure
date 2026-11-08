class Transaction::Grouper::ByMerchantOrName < Transaction::Grouper
  def self.call(entries, limit: 20, offset: 0)
    new(entries).call(limit: limit, offset: offset)
  end

  # The signal a transaction speaks: its merchant (when detected) or its
  # name, plus whether the money went out or came in. Exposed so a single
  # transaction can ask for the other uncategorized rows that share it.
  def self.grouping_key_for(entry)
    merchant_name = entry.entryable.merchant&.name.presence
    type = entry.amount.negative? ? "income" : "expense"

    key = merchant_name || (entry.generic_name? ? "entry:#{entry.id}" : entry.name)
    [ key, type ]
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

    # Entries with no merchant and a generic name (e.g. the auto-generated
    # "Unknown transaction" fallback) get their own singleton key instead of
    # being merged by name -- otherwise unrelated transactions that only share
    # a generic label would be bucketed together, and a rule built from that
    # bucket (Rule.create_from_grouping) would end up matching all of them.
    def grouping_key_for(entry)
      self.class.grouping_key_for(entry)
    end

    # `key` is purely an internal merge key (may be a synthetic per-entry
    # token for generic names, see `grouping_key_for`) -- never surface it
    # directly. `grouping_key`/`display_name` on the Group must stay a
    # human-readable, real transaction name, since the categorize UI displays
    # it and seeds an editable "like" rule condition value from it.
    def build_group(key, entries)
      _, type = key
      merchant = entries.find { |e| e.entryable.merchant.present? }&.entryable&.merchant
      name = merchant&.name || entries.first.name

      Transaction::Grouper::Group.new(
        grouping_key: name,
        display_name: name,
        entries: entries,
        merchant: merchant,
        transaction_type: type
      )
    end
end
