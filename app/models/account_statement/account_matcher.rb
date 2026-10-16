# frozen_string_literal: true

class AccountStatement::AccountMatcher
  Match = Struct.new(:account, :confidence, keyword_init: true)

  MINIMUM_CONFIDENCE = "0.35".to_d

  # The seeded card identity. A last4 that equals the account's own `accounts.last4`
  # COLUMN is the strongest signal a statement carries, so it weighs enough to
  # clear the floor on its own — before this term the matcher only substring-matched
  # the hint against the account's name/institution prose, so seeding an account's
  # last4 produced no suggestion and the statement sat unmatched (the live
  # "Your Triangle" read). The prose term below stays as a secondary signal for a
  # metadata-derived filename like "Chase_Bank_account_6789".
  LAST4_COLUMN_WEIGHT = "0.35".to_d
  LAST4_PROSE_WEIGHT = "0.25".to_d
  # The network a card belongs to, read from the `accounts.account_network` column
  # (never a substring of the prose). Small, like Account::DocumentMatcher's: it
  # only ever breaks a tie two same-bank accounts would otherwise leave open.
  NETWORK_WEIGHT = "0.05".to_d

  attr_reader :statement

  def initialize(statement)
    @statement = statement
  end

  def best_match
    self.class.best_match(
      family: statement.family,
      institution_hint: statement.institution_name_hint,
      account_name_hint: statement.account_name_hint,
      account_last4_hint: statement.account_last4_hint,
      currency: statement.statement_currency
    )
  end

  class << self
    # Hint-based entry point so callers that hold statement metadata without an
    # AccountStatement row (e.g. per-account reconciliation entries extracted
    # from a multi-account PDF) score against the same rules.
    #
    # `card_network` is the card network a caller may know (a statement row
    # carries no network hint today, so the instance path leaves it nil); when
    # present it reads the `accounts.account_network` column to break a tie.
    #
    # `exclude_account_ids` lets a caller resolving several accounts out of one
    # document avoid handing the same account to two different entries.
    def best_match(family:, institution_hint: nil, account_name_hint: nil, account_last4_hint: nil, card_network: nil, currency: nil, exclude_account_ids: [])
      return nil if family.blank?

      institution_hint = normalize_hint(institution_hint)
      account_name_hint = normalize_hint(account_name_hint)
      account_last4_hint = normalize_hint(account_last4_hint)
      card_network = normalize_hint(card_network)

      return nil if institution_hint.blank? && account_name_hint.blank? && account_last4_hint.blank? && card_network.blank?

      excluded = Array.wrap(exclude_account_ids).compact

      candidates = family.accounts.visible.to_a.filter_map do |account|
        next if excluded.include?(account.id)

        confidence = confidence_for(
          account,
          institution_hint: institution_hint,
          account_name_hint: account_name_hint,
          account_last4_hint: account_last4_hint,
          card_network: card_network,
          currency: currency
        )
        next if confidence < MINIMUM_CONFIDENCE

        Match.new(account: account, confidence: confidence.round(4))
      end

      ranked = candidates.sort_by { |match| -match.confidence }
      best = ranked.first
      return nil if best.nil?

      # Two accounts the hints cannot tell apart (identical names at the same
      # institution) would otherwise resolve to whichever the scan reached
      # first. Refuse to guess instead.
      if ranked.length > 1 && ranked[1].confidence == best.confidence
        Rails.logger.warn("AccountStatement::AccountMatcher found equally confident candidates; refusing to guess")
        return nil
      end

      best
    end

    private

      def confidence_for(account, institution_hint:, account_name_hint:, account_last4_hint:, card_network:, currency:)
        score = 0.to_d

        if institution_hint.present?
          text = account_text(account)
          score += 0.45.to_d if text.include?(institution_hint) || Account::InstitutionMatch.match?(institution_hint, text)
        end

        if account_name_hint.present?
          score += 0.25.to_d if account.name.to_s.downcase.include?(account_name_hint)
        end

        if account_last4_hint.present?
          # The seeded identity: the hint's digits against the account's own
          # last4 COLUMN (never a substring of prose). This is the term the live
          # statement needed and never had.
          score += LAST4_COLUMN_WEIGHT if last4_column_matches?(account, account_last4_hint)
          # The legacy prose signal, kept for a filename-derived hint whose
          # "last4" is not a card number (e.g. "Chase_Bank_account_6789").
          score += LAST4_PROSE_WEIGHT if account_sensitive_match_text(account).include?(account_last4_hint)
        end

        if card_network.present?
          score += NETWORK_WEIGHT if account.account_network.to_s.downcase == card_network
        end

        score += 0.05.to_d if currency.present? && currency == account.currency
        [ score, 1.to_d ].min
      end

      def normalize_hint(value)
        value.to_s.downcase.squish.presence
      end

      def last4_column_matches?(account, hint)
        digits = hint.to_s.gsub(/\D/, "")
        digits.present? && account.known_card_last4s.include?(digits)
      end

      def account_text(account)
        [
          account.name,
          account.institution_name,
          account.institution_domain
        ].compact.join(" ").downcase
      end

      def account_sensitive_match_text(account)
        # Exclude user-controlled account notes from matching hints. Statement
        # matching should use conservative account metadata, not free-form prose
        # that can accidentally manufacture a last-four match.
        [
          account.name,
          account.institution_name
        ].compact.join(" ").downcase
      end
  end
end
