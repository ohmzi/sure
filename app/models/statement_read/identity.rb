# frozen_string_literal: true

class StatementRead
  # The statement's identity, parsed from its own text layer: the account
  # number's last four, every card it carries (a supplementary card prints its
  # own purchases block), the network, the issuer and the period. Everything
  # here is printed on the page, so none of it needs a model — and a model
  # asked for it can be wrong (the live June read called a Mastercard "amex").
  class Identity
    # A masked card or account number: four groups, the last of them digits.
    MASKED_NUMBER = /([\dX×*]{4})[\s-]?[\dX×*]{2,6}[\s-]?[\dX×*]{0,6}[\s-]?(\d{4,5})\b/
    ACCOUNT_NUMBER = /Account number:\s*#{MASKED_NUMBER}/i
    CARD_NUMBER = /(?:Card\s*#\s*|Total purchases for\s+)#{MASKED_NUMBER}/i
    ISSUER = /\bis issued by\s+([A-Z][\w&']*(?:\s+[A-Z][\w&']*){0,4})/
    PERIOD_DATE = /(?:[A-Z][a-z]+ \d{1,2}, \d{4}|\d{1,2}\/\d{1,2}\/\d{4})/
    PERIOD = /For the period:\s*(#{PERIOD_DATE})\s+to\s+(#{PERIOD_DATE})/
    NETWORK_WORDS = {
      "visa" => /\bVisa\b/i,
      "mastercard" => /\bMaster\s?card\b/i,
      "amex" => /\bAmerican Express\b|\bAmex\b/i,
      "discover" => /\bDiscover\b/
    }.freeze

    Result = Data.define(:institution_name, :account_last4, :card_last4s, :card_network,
                         :period_start, :period_end) do
      # A card statement needs its network; a chequing or savings statement
      # lists no card, so it has none to need.
      def complete?
        [ account_last4, institution_name, period_start, period_end ].all?(&:present?) &&
          (card_last4s.empty? || card_network.present?)
      end

      # The identity in DocumentUnderstanding's verdict keys, so it can stand in
      # for (or override) the model's identity read.
      def to_verdict_fields
        {
          "document_class" => "statement",
          "institution_name" => institution_name,
          "account_last4" => account_last4,
          "card_last4" => card_last4s.first || account_last4,
          "card_network" => card_network,
          "statement_period" => ({ "start" => period_start&.iso8601, "end" => period_end&.iso8601 } if period_start || period_end)
        }.compact
      end
    end

    def self.call(text) = new(text).call

    def initialize(text)
      @text = text.to_s
    end

    def call
      account = @text.match(ACCOUNT_NUMBER)
      cards = @text.scan(CARD_NUMBER).map { |(_, last)| last.last(4) }.uniq
      start_on, end_on = period

      Result.new(
        institution_name: @text[ISSUER, 1]&.sub(/[.,]\z/, "")&.squish,
        account_last4: account && account[2].last(4),
        card_last4s: cards,
        card_network: network(account&.[](1) || @text.match(CARD_NUMBER)&.[](1)),
        period_start: start_on,
        period_end: end_on
      )
    end

    private
      # The number's issuer prefix decides; without one, the text's single
      # network name does. Two names (an ad for another card) decide nothing.
      def network(prefix)
        by_prefix = network_for_prefix(prefix)
        return by_prefix if by_prefix

        named = NETWORK_WORDS.select { |_, pattern| @text.match?(pattern) }.keys
        named.one? ? named.first : nil
      end

      def network_for_prefix(prefix)
        return nil if prefix.blank? || prefix.start_with?("0")

        two = prefix.first(2).to_i
        four = prefix.first(4).to_i
        return "visa" if prefix.start_with?("4")
        return "amex" if [ 34, 37 ].include?(two)
        return "mastercard" if (51..55).cover?(two) || (2221..2720).cover?(four)
        return "discover" if prefix.start_with?("6011", "65")

        nil
      end

      def period
        match = @text.match(PERIOD)
        return [ nil, nil ] unless match

        [ parse_date(match[1]), parse_date(match[2]) ]
      end

      def parse_date(value)
        value.include?("/") ? Date.strptime(value, "%m/%d/%Y") : Date.parse(value)
      rescue Date::Error
        nil
      end
  end
end
