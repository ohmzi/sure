class ReceiptMatcher::Extraction
  # Expense amounts are positive, matching Sure's Entry sign convention (a
  # $55.00 purchase is stored as 55.00). A refund total parsed as negative stays
  # negative. `date` and `payee` are optional enrichments; only the amount is
  # required (a missing amount yields nil from the Extractor, not a partial
  # Extraction).
  attr_reader :amount, :date, :payee

  def initialize(amount:, date: nil, payee: nil)
    @amount = amount
    @date = date
    @payee = payee
  end

  def complete?
    amount.present?
  end
end
