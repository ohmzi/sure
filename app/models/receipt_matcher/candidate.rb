class ReceiptMatcher::Candidate
  attr_reader :entry, :score, :day_distance, :payee_similarity

  def initialize(entry:, score:, day_distance:, payee_similarity:, exact_amount:)
    @entry = entry
    @score = score
    @day_distance = day_distance
    @payee_similarity = payee_similarity
    @exact_amount = exact_amount
  end

  def exact_amount?
    @exact_amount
  end

  # Ordering key: exact amount first, then nearest date, then best payee match,
  # then the oldest entry as a stable tiebreak.
  def rank_key
    [ exact_amount? ? 0 : 1, day_distance, -payee_similarity.round(2), entry.created_at ]
  end
end
