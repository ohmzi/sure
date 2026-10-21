# Fills missing categories for well-known merchant descriptions. The patterns
# are deliberately generic public brands; family-specific merchants should be
# handled as data, not committed source. Each rule only matches uncategorized
# transactions, so an existing (or user-locked) category is never overwritten.
class Category::MerchantCategorizer
  # Amazon is always Shopping — including Prime, Channels and marketplace
  # variants — regardless of what a provider guessed.
  AMAZON_PATTERN = /amazon|amzn/i

  PATTERNS = [
    [ "Subscriptions", /apple\.com\/bill|netflix|spotify|disney\+|crave|youtube|google\s*\*|adobe|microsoft|github|cursor|anthropic|openai|claude|chatgpt/i ],
    [ "Groceries", /sobeys|loblaws|no\s+frills|freshco|food\s+basics|metro\s+\d|super\s*c|longo|whole\s*foods|costco|bulk\s*barn|foodland|provigo|safeway|save-on|farm\s*boy/i ],
    [ "Home Improvement", /home\s*depot|rona\b|ikea|home\s*hardware/i ],
    [ "Transportation", /(?:^|[^a-z])esso(?:[^a-z]|$)|petro-canada|(?:^|[^a-z])shell(?:[^a-z]|$)|sunoco|(?:^|[^a-z])wawa(?:[^a-z]|$)|couche-tard|onroute|ultramar|exxon|(?:^|[^a-z])mobil(?:[^a-z]|$)|circle\s*k|husky|pioneer|parking|parkedin|u-haul|hertz|(?:^|[^a-z])avis(?:[^a-z]|$)|(?:canadian|cdn)\s*tire\s*(?:gas|gasbar)/i ],
    [ "Food & Drink", /tim\s*hortons|second\s*cup|starbucks|mcdonald|subway|domino|kfc|taco|pizza|burger|restaurant|cafe|coffee|bakery|bistro|grill|(?:^|[^a-z])deli(?:[^a-z]|$)|sushi/i ],
    [ "Healthcare", /pharmaprix|shoppers\s*drug\s*mart|cvs\/pharmacy|walgreens|rexall|pharmacy|dental|clinic|hospital|medical/i ],
    [ "Entertainment", /cineplex|cinema|theatre|museum|ticketmaster|playstation|xbox|nintendo|steam\s*games|steamgames/i ],
    [ "Travel", /holiday\s*inn|marriott|hilton|hotel|airbnb|booking\.com|expedia|air\s*canada|westjet|porter|via\s*rail/i ],
    [ "Pet", /pet\s*smart|petland|pet\s*foods/i ],
    [ "Personal Care", /barber|salon|(?:^|[^a-z])spa(?:[^a-z]|$)|(?:^|[^a-z])hair(?:[^a-z]|$)|beauty/i ],
    [ "Sports & Fitness", /fitness|(?:^|[^a-z])gym(?:[^a-z]|$)|goodlife|ymca|sport\s*chek|decathlon/i ],
    [ "Insurance", /insurance|belair|aviva/i ],
    [ "Taxes", /revenue\s*canada|(?:^|[^a-z])tax(?:[^a-z]|$)/i ],
    [ "Gifts & Donations", /donation|foundation|charity|church|mosque|temple|unicef|red\s*cross/i ],
    [ "Fees", /dhl|customs|(?:^|[^a-z])nsf(?:[^a-z]|$)|service\s*charge|interest\s*charge|bank\s*fee|monthly\s*fee/i ],
    [ "Cash Withdrawal", /(?:^|[^a-z])atm(?:[^a-z]|$)|cash\s*withdrawal/i ],
    [ "Cash Deposited", /cash\s*deposit/i ],
    [ "Shopping", /amazon|amzn|ebay|etsy|aliexpress|winners|tj\s*maxx|carters|adidas|dollarama|staples|officemax|best\s*buy|walmart|(?:canadian|cdn)\s*tire(?!\s+(?:bank|gas|mc))|wayfair|apple\.com\/ca|apple\s+store|costco/i ]
  ].freeze

  Result = Data.define(:category, :rule, :updated)

  def initialize(family)
    @family = family
  end

  # One result per category whose rule exists in the family. Re-running reuses
  # the rule and reports 0 for rows already categorized.
  def call
    results = [ apply_rule("Shopping", AMAZON_PATTERN, name: "Amazon is Shopping", only_uncategorized: false) ]
    PATTERNS.each do |name, pattern|
      results << apply_rule(name, pattern, name: "Categorize #{name} merchants", only_uncategorized: true)
    end
    results.compact
  end

  private
    def apply_rule(category_name, pattern, name:, only_uncategorized:)
      category = @family.categories.find_by(name: category_name)
      return nil unless category

      rule = upsert_rule(category, pattern, name: name, only_uncategorized: only_uncategorized)
      updated = rule.actions.sum { |action| action.apply(rule.matching_scope) }
      Result.new(category: category, rule: rule, updated: updated)
    end

    def upsert_rule(category, pattern, name:, only_uncategorized:)
      rule = @family.rules.find_or_initialize_by(name: name, resource_type: "transaction")
      rule.conditions.destroy_all if rule.persisted?
      rule.actions.destroy_all if rule.persisted?
      rule.active = true
      rule.conditions.build(condition_type: "transaction_name", operator: "matches_regex", value: pattern.source,
                            skip_regex_safety_validation: true)
      rule.conditions.build(condition_type: "transaction_category", operator: "is_null") if only_uncategorized
      rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
      rule.save!
      rule
    end
end
