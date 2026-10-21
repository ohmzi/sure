# Creates the canonical family merchants and the rules that keep their
# variants together. The dashboard chart also normalizes names on the fly, so
# a new variant is grouped even before a rule runs; the rule persists the
# canonical merchant on the transaction.
class Merchant::Canonicalizer
  require "zlib"

  Result = Data.define(:name, :merchant, :rule, :updated)

  def initialize(family)
    @family = family
  end

  # Returns one Result per canonical merchant that currently has matching
  # transactions. Re-running is safe: the existing merchant and rule are
  # reused, and already-assigned transactions report 0 updates.
  def call
    Merchant::NameNormalizer::RULES.filter_map do |name, pattern|
      scope = @family.transactions.with_entry.where("entries.name ~* ?", pattern.source)
      next unless scope.exists?

      merchant = find_or_create_merchant(name)
      rule = upsert_rule(name, pattern, merchant)
      updated = rule.actions.sum { |action| action.apply(rule.matching_scope) }
      record_merge(merchant, updated) if updated.positive?

      Result.new(name: name, merchant: merchant, rule: rule, updated: updated)
    end
  end

  private
    def find_or_create_merchant(name)
      merchant, = FamilyMerchant.find_or_create_with_name(
        @family,
        name,
        color: FamilyMerchant::COLORS[Zlib.crc32(name) % FamilyMerchant::COLORS.size]
      )
      merchant
    end

    def upsert_rule(name, pattern, merchant)
      rule = @family.rules.find_or_initialize_by(
        name: "Canonical merchant: #{name}",
        resource_type: "transaction"
      )
      rule.conditions.destroy_all if rule.persisted?
      rule.actions.destroy_all if rule.persisted?
      rule.active = true
      rule.conditions.build(condition_type: "transaction_name", operator: "matches_regex", value: pattern.source,
                            skip_regex_safety_validation: true)
      rule.actions.build(action_type: "set_transaction_merchant", value: merchant.id.to_s)
      rule.save!
      rule
    end

    def record_merge(merchant, updated)
      AuditLog.record_best_effort!(
        auditable: merchant,
        family: @family,
        action: "merchant.merged",
        source: "canonicalizer",
        metadata: {
          "to_merchant_id" => merchant.id,
          "to_merchant_name" => merchant.name,
          "affected_count" => updated
        }
      )
    end
end
