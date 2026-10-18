# Canonical merchant names shared by the dashboard chart and the rule/backfill
# path. The patterns are plain PostgreSQL-compatible regexes (the rules use
# `~*`), so the same source maps an entry name in Ruby and in SQL.
class Merchant::NameNormalizer
  RULES = {
    "Amazon" => /amazon|amzn/i,
    "Home Depot" => /home\s*depot/i,
    "Dollarama" => /dollarama/i,
    "IKEA" => /(?:^|[^a-z])ikea(?:[^a-z]|$)/i,
    "Staples" => /staples/i,
    "Pharmaprix" => /pharmaprix/i,
    "AliExpress" => /aliexpress/i,
    "Apple" => /apple\.com|apple\s+store/i,
    "Etsy" => /etsy/i,
    "RONA" => /(?:^|[^a-z])rona(?:[^a-z]|$)/i,
    "Maxi" => /(?:^|[^a-z])maxi(?:[^a-z]|$)/i,
    "Giant Tiger" => /giant\s+tiger/i,
    "TJ Maxx" => /tj\s*maxx/i,
    "Carter's" => /carters/i,
    "Adidas" => /adidas/i,
    "Sport Chek" => /sport\s*chek/i,
    "Walmart" => /wal-?mart/i,
    "Costco" => /costco/i,
    "Best Buy" => /best\s*buy/i,
    "Canadian Tire" => /canadian\s+tire|cdn\s+tire/i,
    "Shoppers Drug Mart" => /shoppers\s+drug\s+mart/i,
    "Loblaws" => /loblaws/i,
    "No Frills" => /no\s+frills/i,
    "Sobeys" => /sobeys/i,
    "FreshCo" => /freshco/i,
    "Food Basics" => /food\s+basics/i,
    "Wayfair" => /wayfair/i,
    "eBay" => /ebay/i
  }.freeze

  class << self
    def canonical_name(name)
      value = name.to_s.squish
      return value if value.blank?

      RULES.each do |canonical, pattern|
        return canonical if pattern.match?(value)
      end

      value
    end
  end
end
