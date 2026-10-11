class ReceiptMatcher::Extraction
  # Expense amounts are positive, matching Sure's Entry sign convention (a
  # $55.00 purchase is stored as 55.00). v1 parses money tokens as unsigned: a
  # refund/negative total is read as a positive amount — accepted v1 semantics
  # (Ruling M3-C2 R6, 2026-10-11 close-out), with its bounded consequence: a
  # sign-flipped amount fails to match (no_match, never a wrong link). `date`
  # and `payee` are optional enrichments; only the amount is required (a missing
  # amount yields nil from the Extractor, not a partial Extraction).
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
