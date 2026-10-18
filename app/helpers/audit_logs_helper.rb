# frozen_string_literal: true

# Read-side formatting for the append-only audit trail. The stored row keeps
# raw ids and snapshotted display names; this helper turns a changed field into
# a sentence a person can read without another query.
module AuditLogsHelper
  def audit_actor_name(log)
    log.actor&.display_name.presence || t("audit_logs.activity.system")
  end

  def audit_action_label(log)
    t("audit_logs.activities.#{log.action}", default: log.action.humanize)
  end

  def audit_change_descriptions(log)
    fields = Array(log.metadata["fields"])
    fields.filter_map do |field|
      next if field == "updated_at"

      t(
        "audit_logs.activity.change",
        field: t("audit_logs.fields.#{field}", default: field.humanize),
        from: audit_display_value(log, log.before || {}, field),
        to: audit_display_value(log, log.after || {}, field)
      )
    end
  end

  # A short, action-specific detail line for events that have no before/after
  # money field (a publish, a delete). Returns nil when there is nothing to add.
  def audit_event_detail(log)
    case log.action
    when "import.published", "import.reverted"
      t("audit_logs.activity.rows", count: log.metadata["rows_count"].to_i)
    when "document.deleted"
      log.metadata["filename"].presence && t("audit_logs.activity.document", filename: log.metadata["filename"])
    when "account_statement.deleted"
      filename = (log.before || {})["filename"]
      filename.presence && t("audit_logs.activity.statement", filename: filename)
    when "category.merged", "merchant.merged", "transactions.bulk_recategorized",
         "merchant.converted", "merchant.unlinked"
      t("audit_logs.activity.affected", count: log.metadata["affected_count"].to_i)
    end
  end

  def audit_display_value(log, values, field)
    name_key = "#{field.delete_suffix('_id')}_name"
    name = values[name_key]
    return name if values[field].present? && name.present?

    value = values[field]
    return t("audit_logs.activity.none") if value.nil?

    case field
    when "amount", "opening_balance", "closing_balance"
      currency = log.metadata["currency"].presence || Current.family&.currency || "USD"
      Money.new(value.to_d, currency).format
    when "date", "period_start_on", "period_end_on"
      format_date(value)
    when "kind"
      t("audit_logs.kinds.#{value}", default: value.to_s.humanize)
    when "transfer_id"
      t("audit_logs.activity.transfer_paired")
    when "currency"
      value.to_s
    when "filename"
      value.to_s
    else
      value.to_s
    end
  end
end
