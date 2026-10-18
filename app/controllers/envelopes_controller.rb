class EnvelopesController < ApplicationController
  include BudgetOwnership
  # The gesture turbo streams call bare `dom_id`; ChatsController includes this
  # for the same reason.
  include ActionView::RecordIdentifier

  before_action :set_budget, only: %i[show update assign move cover]
  before_action :ensure_budget_editable!, only: %i[update assign move cover]

  def index
    redirect_to envelope_path(Budget.date_to_param(Date.current), **budget_owner_query)
  end

  def show
    @editable = @budget.editable_by?(Current.user)
    @switch_options = budget_switch_options(@budget)
    @source_budget = @budget.most_recent_initialized_budget unless @budget.initialized?
    @account_groups = EnvelopesHelper.account_columns(@budget)
    @envelope_groups = BudgetCategory::Group.for(@budget.budget_categories.includes(:category))
    @breadcrumbs = plan_breadcrumb_prefix + [ [ t("breadcrumbs.budgets"), nil ] ]
  end

  def update
    @budget.update!(budget_params)
    redirect_to envelope_path(@budget.to_param, **budget_owner_query)
  end

  # Inline assignment from a row: one envelope, one amount, through the
  # existing update_budgeted_spending! seam. Recomputed through the shared
  # Budget::Recalculate seam, after the write commits.
  def assign
    budget_category = @budget.budget_categories.find(params[:id])
    budget_category.update_budgeted_spending!(assigned_amount_param)
    Budget::Recalculate.call(family: @budget.family, budget: @budget)
    @budget.sync_budgeted_spending!

    @budget.reload
    respond_to do |format|
      format.turbo_stream do
        # Ruling M4-L4 (2026-10-10 close-out): the gesture moves money on the
        # whole surface, so the stream refreshes the money figures the row
        # cannot show -- the ready-to-assign banner and the credit-card
        # payments group -- not only the touched row.
        render turbo_stream: [
          # Morphed, so the row's ring and bar slide to the new fill.
          turbo_stream.replace(
            dom_id(budget_category, :envelope),
            method: :morph,
            partial: "envelopes/envelope_row",
            locals: { budget_category: budget_category.reload, budget: @budget }
          ),
          turbo_stream.replace(
            dom_id(@budget, :ready_to_assign),
            partial: "envelopes/ready_to_assign",
            locals: { budget: @budget }
          ),
          turbo_stream.replace(
            dom_id(@budget, :credit_card_payments),
            partial: "envelopes/credit_card_group",
            locals: { budget: @budget }
          )
        ]
      end
      format.html { redirect_to envelope_path(@budget.to_param, **budget_owner_query) }
    end
  rescue ActiveRecord::RecordInvalid
    head :unprocessable_entity
  end

  # Fills the red envelope from a donor, one gesture, through the existing
  # move_allocation! seam. The recompute runs AFTER the move commits, never
  # inside it: the calculator takes an advisory lock, and taking it while the
  # move holds its row locks inverts the lock order (see
  # BudgetCategory.move_allocation!). It goes through Budget::Recalculate so
  # M4b extends one seam rather than each write path.
  def cover
    @from = @budget.budget_categories.find(params[:from_id])
    @to = @budget.budget_categories.find(params[:to_id])

    BudgetCategory.move_allocation!(from: @from, to: @to, amount: move_amount_param)
    Budget::Recalculate.call(family: @budget.family, budget: @budget)

    @budget.sync_budgeted_spending!
    @budget.reload
    # Explicit key, not `t(".success")`: #move delegates to #cover, so a bare
    # dot-key would resolve as `envelopes.move.success`, which no task defines
    # (Ruling P-m4a-1, 2026-10-10 pre-flight).
    flash.now[:notice] = t("envelopes.cover.success")
    respond_to do |format|
      format.turbo_stream { render :cover }
      format.html { redirect_to envelope_path(@budget.to_param, **budget_owner_query), notice: t("envelopes.cover.success") }
    end
  rescue BudgetCategory::InvalidMove => e
    flash.now[:alert] = e.message
    respond_to do |format|
      format.turbo_stream { render turbo_stream: flash_notification_stream_items, status: :unprocessable_entity }
      format.html { redirect_to envelope_path(@budget.to_param, **budget_owner_query), alert: e.message, status: :see_other }
    end
  end

  # The same gesture as cover: move money from one envelope to another. One
  # implementation, rendered through cover's stream.
  def move
    cover
  end

  private
    def budget_params
      params.require(:budget).permit(:expected_income)
    end

    def assigned_amount_param
      params.require(:budget_category).permit(:budgeted_spending)
            .fetch(:budgeted_spending, nil).presence || 0
    end

    def move_amount_param
      params.require(:budget_category_move).permit(:amount).fetch(:amount, nil).to_d
    end

    # The gesture routes are collection routes (/envelopes/cover) with no month
    # in the path, so the viewed month arrives as a `month_year` param that
    # every gesture form carries; without one it falls back to the current
    # month. This is what lets a cover issued from a later month's page mutate
    # that month's rows rather than the current month's.
    def set_budget
      param = params[:month_year].presence || Budget.date_to_param(Date.current)
      start_date = Budget.param_to_date(param, family: Current.family)
      @budget = resolve_budget(start_date)
      raise ActiveRecord::RecordNotFound unless @budget
    end
end
