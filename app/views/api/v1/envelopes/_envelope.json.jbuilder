# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end
include_derived_amounts = local_assigns.fetch(:include_derived_amounts, true)

json.id envelope.id
json.budget_id envelope.budget_id
json.currency envelope.currency
json.subcategory envelope.subcategory?
json.inherits_parent_budget envelope.inherits_parent_budget?

json.rollover_enabled envelope.rollover_enabled?

json.target_type envelope.target_type
json.target_date envelope.target_date
json.target_amount envelope.target_amount
target_money = Money.new(envelope.target_amount, envelope.currency) if envelope.target_amount
json.target_amount_cents money_to_minor_units.call(target_money)

json.budgeted_spending envelope.budgeted_spending_money.format
json.budgeted_spending_cents money_to_minor_units.call(envelope.budgeted_spending_money)
json.display_budgeted_spending Money.new(envelope.display_budgeted_spending, envelope.currency).format
json.display_budgeted_spending_cents money_to_minor_units.call(Money.new(envelope.display_budgeted_spending, envelope.currency))
if include_derived_amounts
  json.actual_spending envelope.actual_spending_money.format
  json.actual_spending_cents money_to_minor_units.call(envelope.actual_spending_money)
  # Sits with the derived amounts because it is what makes available_to_spend
  # exceed budgeted_spending: without it a client sees the larger number with
  # nothing to account for the difference.
  displayed_rollover = Money.new(envelope.display_rolled_over_amount, envelope.currency)
  json.rolled_over_amount displayed_rollover.format
  json.rolled_over_amount_cents money_to_minor_units.call(displayed_rollover)
  json.available_to_spend envelope.available_to_spend_money.format
  json.available_to_spend_cents money_to_minor_units.call(envelope.available_to_spend_money)
end

json.category do
  json.id envelope.category.id
  json.name envelope.category.name
  json.color envelope.category.color
  json.lucide_icon envelope.category.lucide_icon
  json.parent_id envelope.category.parent_id
end

json.created_at envelope.created_at.iso8601
json.updated_at envelope.updated_at.iso8601
