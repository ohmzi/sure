module RulesHelper
  # Renders a preview value with a readable label for the values that have no
  # natural one: a nil category/merchant and the excluded flag.
  def rule_preview_value(value, action_type)
    if value.nil?
      if action_type == "set_transaction_category"
        t("rules.apply_all.preview.uncategorized")
      else
        t("rules.apply_all.preview.none")
      end
    elsif value == true
      t("rules.apply_all.preview.excluded")
    elsif value == false
      t("rules.apply_all.preview.included")
    else
      value
    end
  end
end
