# frozen_string_literal: true

# Whether a document's issuer names the same institution as an account.
# Statements name the issuer ("Canadian Tire Bank") while people name the
# account after the product ("Canadian Tire Mastercard"), so a plain substring
# test never matched the owner's June statement. The significant words decide:
# product and filler words are ignored, and the issuer's significant words must
# all appear in the account's own text.
module Account::InstitutionMatch
  FILLER = %w[
    bank card credit debit mastercard visa amex american express discover world elite infinite
    rewards cash back the of and financial services inc ltd corp corporation co plc na
  ].freeze

  def self.match?(hint, account_text)
    hint_words = significant_words(hint)
    return false if hint_words.empty?

    (hint_words - significant_words(account_text)).empty?
  end

  def self.significant_words(text)
    text.to_s.downcase.scan(/[a-z0-9]+/).select { |word| word.length >= 3 }.uniq - FILLER
  end
end
