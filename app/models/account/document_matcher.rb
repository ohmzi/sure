# frozen_string_literal: true

# Which account (or card) is this document for?
#
# Built beside AccountStatement::AccountMatcher, not on top of it. Both read the
# `accounts.last4` COLUMN now; this one additionally requires spec §7.5's OCR
# witness before a last4 may score, and prefills above the bar.
#
# It refuses ties and returns nil when it is not sure, because the alternative
# is silently filing a statement under the wrong card — and the step-3 ask is
# already the app's one ambiguity path.
class Account::DocumentMatcher
  Match = Struct.new(:account, :confidence, keyword_init: true)

  MINIMUM_CONFIDENCE = "0.35".to_d
  # At or above this, the account is prefilled without asking. Deliberately well
  # above the floor: a wrong prefill is a silently wrong ledger, a missing
  # prefill is one tap.
  AUTO_PREFILL_BAR = "0.6".to_d

  WEIGHT_INSTITUTION = "0.35".to_d
  WEIGHT_NAME = "0.20".to_d
  WEIGHT_NETWORK = "0.05".to_d
  WEIGHT_CURRENCY = "0.05".to_d

  # Spec §7.5's second witness, as a GATE not a bonus. A last4 hint scores ONLY
  # when its digits also appear in the OCR text — the second witness against a
  # validly-typed but wrong (or hallucinated) number. An unwitnessed last4
  # contributes ZERO, so it can never lift a match toward the bar (institution
  # 0.35 + an unwitnessed last4 stays at 0.35, well below 0.60). A witnessed
  # column match weighs enough to clear the bar on its own. The wrong-card and
  # tie protections are untouched: the term still requires an exact
  # `accounts.last4` COLUMN match, and two accounts sharing that last4 still tie
  # and are refused.
  WEIGHT_LAST4_WITNESSED = "0.60".to_d

  def self.best_match(family:, institution_hint: nil, account_name_hint: nil,
                      account_last4_hint: nil, card_network: nil, currency: nil,
                      last4_witness: false, exclude_account_ids: [])
    return nil if family.blank?

    institution = normalize(institution_hint)
    name = normalize(account_name_hint)
    last4 = digits(account_last4_hint)
    network = card_network.to_s.downcase.presence

    return nil if [ institution, name, last4, network ].all?(&:blank?)

    excluded = Array.wrap(exclude_account_ids).compact

    ranked = family.accounts.visible.filter_map do |account|
      next if excluded.include?(account.id)

      score = score_for(account, institution:, name:, last4:, network:, currency:, last4_witness:)
      next if score < MINIMUM_CONFIDENCE

      Match.new(account: account, confidence: score.round(4))
    end.sort_by { |match| -match.confidence }

    best = ranked.first
    return nil if best.nil?

    # Two accounts the hints cannot tell apart (same institution, no last4 on
    # either) would otherwise resolve to whichever the scan reached first.
    return nil if ranked.length > 1 && ranked[1].confidence == best.confidence

    best
  end

  def self.score_for(account, institution:, name:, last4:, network:, currency:, last4_witness: false)
    score = 0.to_d

    text = [ account.name, account.institution_name, account.institution_domain ].compact.join(" ").downcase
    score += WEIGHT_INSTITUTION if institution.present? && text.include?(institution)
    score += WEIGHT_NAME if name.present? && account.name.to_s.downcase.include?(name)

    # The new terms: a real column, not a substring of the account's prose. The
    # last4 term is GATED on the OCR witness (spec §7.5): a hint whose digits the
    # page never carried contributes nothing, so a validly-typed but wrong number
    # cannot drive a prefill. Only a witnessed exact column match scores.
    if last4.present? && account.last4.present? && account.last4 == last4 && last4_witness
      score += WEIGHT_LAST4_WITNESSED
    end
    score += WEIGHT_NETWORK if network.present? && account.account_network.to_s.downcase == network
    score += WEIGHT_CURRENCY if currency.present? && currency == account.currency

    [ score, 1.to_d ].min
  end

  def self.normalize(value) = value.to_s.downcase.squish.presence

  def self.digits(value)
    text = value.to_s.gsub(/\D/, "")
    text.presence
  end

  private_class_method :score_for
end
