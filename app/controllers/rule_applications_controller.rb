class RuleApplicationsController < ApplicationController
  before_action :require_non_guest!

  # Undoes a whole apply-all batch. A rule's application row identifies the
  # batch, so the owner can reach the undo from that rule's review page.
  def undo
    application = Current.family.rule_applications.find(params[:id])

    RuleApplication.undo_batch!(
      family: Current.family,
      batch_id: application.batch_id,
      actor: Current.user
    )

    redirect_to rule_path(application.rule), notice: t("rules.applications.undo_success")
  rescue RuleApplication::AlreadyUndone
    redirect_to rule_path(application.rule), alert: t("rules.applications.already_undone")
  end
end
