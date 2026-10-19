# Sends a transaction's money to the account its category names (the owner,
# 2026-10-19: label a charge "Investment Contributions" and it goes to the
# investment account chosen for that category in Settings).
#
# The charge stays where it is and becomes the outflow of a confirmed
# transfer; a matching inflow is added to the destination account, as the
# transfer-match dialog does for "create a new transaction". Confirming the
# transfer gives the outflow its transfer kind (an investment contribution
# when the source isn't itself an investment account), so it leaves budgets.
#
# Only an outflow that isn't already part of a transfer, isn't in the
# destination account itself, shares its currency and isn't excluded or a
# split parent is routed; anything else is left alone, so routing twice is
# harmless.
class Transaction::CategoryRouting
  DESTINATION_TYPES = %w[Investment Crypto].freeze

  attr_reader :transaction

  def initialize(transaction)
    @transaction = transaction
  end

  def routable?
    destination = transaction.category&.destination_account
    return false if destination.nil?

    # A transaction saved before its entry (Entry.create! with an existing
    # Transaction) has none yet; don't leave that empty lookup cached.
    entry = transaction.entry
    if entry.nil?
      transaction.association(:entry).reset
      return false
    end

    return false unless entry.amount.positive?
    return false if transaction.transfer.present?
    return false if entry.excluded? || entry.split_parent?
    return false if destination.id == entry.account_id
    return false if destination.family_id != entry.account.family_id
    return false if destination.currency != entry.currency

    true
  end

  # Returns true when it moved the money.
  def route!
    return false unless routable?

    entry = transaction.entry
    destination = transaction.category.destination_account

    inflow = Transaction.new(
      entry: destination.entries.build(
        amount: -entry.amount,
        currency: entry.currency,
        date: entry.date,
        name: entry.name,
        user_modified: true
      )
    )

    transfer = Transfer.new(inflow_transaction: inflow, outflow_transaction: transaction, status: "confirmed")
    Transfer.transaction do
      transfer.save!
      transfer.confirm!
    end
    transfer.sync_account_later

    true
  end
end
