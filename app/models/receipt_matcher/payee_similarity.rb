# Normalized-payee fuzzy score in 0.0..1.0. Names are downcased, stripped of
# punctuation and collapsed to their first three words — the same first-three-words
# normalization Entry.reconcile_pending_duplicates uses (app/models/entry.rb:235,
# where punctuation is deleted; here it is folded to a space so word boundaries
# survive) — then compared as character bigrams with the Sørensen–Dice
# coefficient. Deterministic and dependency-free; a blank side scores 0.0.
class ReceiptMatcher::PayeeSimilarity
  def self.call(a, b)
    new(a, b).call
  end

  def initialize(a, b)
    @a = normalize(a)
    @b = normalize(b)
  end

  def call
    return 0.0 if @a.empty? || @b.empty?
    return 1.0 if @a == @b

    a_bigrams = bigrams(@a)
    b_bigrams = bigrams(@b)
    return 0.0 if a_bigrams.empty? || b_bigrams.empty?

    overlap = (a_bigrams & b_bigrams).length
    (2.0 * overlap) / (a_bigrams.length + b_bigrams.length)
  end

  private
    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").split.first(3).join(" ")
    end

    def bigrams(string)
      string.length < 2 ? [ string ] : string.chars.each_cons(2).map(&:join)
    end
end
