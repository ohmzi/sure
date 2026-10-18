# The single place that answers "which claimed attributes exclude this action,
# and which attributes does it claim for the rules below it?".
#
# Rule#apply (execution) and Rule::ApplicationPreview (confirmation) must agree
# on both answers. In particular, an async AI action exposes claimed attributes
# but deliberately does not reserve them for lower rules; its own scope is still
# narrowed by claims a higher rule made.
module Rule::ActionClaims
  module_function

  # Transaction ids a higher rule already claimed for an attribute this action
  # writes. This applies even to actions that do not reserve claims for rules
  # below them (e.g. auto_categorize).
  def excluded_ids(action, claimed_ids)
    action.claimed_attributes.flat_map { |attribute| claimed_ids.fetch(attribute, []).to_a }.uniq
  rescue => e
    log_unreadable(action, e)
    []
  end

  # Attributes this action keeps for itself when the rules below run. An action
  # that cannot be resolved or applied claims nothing.
  def reserved_attributes(action)
    return [] unless action.reserves_claimed_attributes?

    action.claimed_attributes
  rescue => e
    log_unreadable(action, e)
    []
  end

  def record(action, matched_ids, claimed_ids)
    reserved_attributes(action).each { |attribute| claimed_ids[attribute].merge(matched_ids) }
  end

  def log_unreadable(action, error)
    Rails.logger.warn(
      "Rule::ActionClaims could not read claims of action #{action.id}: #{error.class}: #{error.message}"
    )
  end
end
