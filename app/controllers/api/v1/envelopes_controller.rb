# frozen_string_literal: true

class Api::V1::EnvelopesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :update, :destroy ]
  before_action :set_envelope, only: [ :show, :update, :destroy ]

  def index
    @pagy, @envelopes = pagy(envelopes_scope.order(:created_at),
                             page: safe_page_param, limit: safe_per_page_param)
    @per_page = safe_per_page_param
    render :index
  end

  def show = render(:show)

  def update
    @envelope.update_budgeted_spending!(budgeted_spending_param) if params.dig(:envelope, :budgeted_spending)

    if params.dig(:envelope, :rollover_enabled)
      @envelope.update!(rollover_enabled: ActiveModel::Type::Boolean.new.cast(params[:envelope][:rollover_enabled]))
      @envelope.propagate_rollover_choice_forward!
    end

    # Ruling 5: all-or-nothing — BOTH keys must be present (same rule as the
    # web controller), so a lone key can never write a half-target.
    if params.require(:envelope).key?(:target_type) && params.require(:envelope).key?(:target_amount)
      @envelope.update!(target_params)
      @envelope.propagate_target_choice_forward!
    end

    Budget::Recalculate.call(family: @envelope.budget.family, budget: @envelope.budget)
    @envelope.budget.sync_budgeted_spending!
    @envelope.reload
    render :show
  rescue BudgetCategory::InvalidMove => e
    render_validation_error(e.message)
  end

  def destroy
    budget = @envelope.budget
    @envelope.destroy!
    Budget::Recalculate.call(family: budget.family, budget: budget)
    budget.sync_budgeted_spending!
    render_json({ message: "Envelope deleted successfully" }, status: :ok)
  end

  private
    def ensure_read_scope = authorize_scope!(:read)
    def ensure_write_scope = authorize_scope!(:write)

    def set_envelope
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @envelope = envelopes_scope.find(params[:id])
    end

    def envelopes_scope
      current_resource_owner.family.budgets
        .where(user_id: visible_owner_ids)
        .flat_map(&:budget_categories)  # envelopes are per-budget categories
        .then { |rows| BudgetCategory.where(id: rows.map(&:id)).includes(:category, :budget) }
    end

    def visible_owner_ids
      shared = BudgetShare.where(viewer_id: current_resource_owner.id).pluck(:owner_id)
      [ nil, current_resource_owner.id, *shared ]
    end

    def budgeted_spending_param
      params.require(:envelope).permit(:budgeted_spending).fetch(:budgeted_spending, 0).presence || 0
    end

    # Blank values clear the target; the columns are nullable and the
    # inclusion/range validations allow nil (same rule as the allocation form).
    def target_params
      params.require(:envelope).permit(:target_amount, :target_type, :target_date)
            .to_h.transform_values { |value| value.presence }
    end
end
