# frozen_string_literal: true

class Api::V1::EnvelopesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :update, :destroy ]
  # Ruling M4a-L3: serve fresh derived money, the sibling budget_categories API's
  # own bargain (writes nothing for a family without rollover).
  # Ruling M4a-L3b: declared BEFORE set_envelope — the loader must load the
  # refreshed row; the refresh's upsert_all fixes the DB but not an
  # already-loaded instance, so with the loader first `show` rendered the stale
  # carry. Same order as the sibling controller (refresh at :7, loader at :8).
  before_action :refresh_rollover_chains, only: [ :index, :show ]
  before_action :set_envelope, only: [ :show, :update, :destroy ]
  # Ruling M4a-L3 (Critical): the API key scope is not the only gate — a
  # read_only BudgetShare must not write either. 404, exactly like the web
  # surface's gated actions.
  before_action :ensure_budget_writable, only: [ :update, :destroy ]

  def index
    @pagy, @envelopes = pagy(envelopes_scope.order(:created_at),
                             page: safe_page_param, limit: safe_per_page_param)
    @per_page = safe_per_page_param
    render :index
  end

  def show = render(:show)

  def update
    # Ruling M4a-L3 (Important): ONE transaction for the WRITES — a combined
    # payload (money + an invalid target) must not leave the money write
    # committed while the target write is rejected.
    BudgetCategory.transaction do
      @envelope.update_budgeted_spending!(budgeted_spending_param) if params.dig(:envelope, :budgeted_spending)

      # Ruling M4a-L3 (Important): key PRESENCE, not truthiness — `false` is a
      # legitimate value and must apply and propagate.
      if params.require(:envelope).key?(:rollover_enabled)
        @envelope.update!(rollover_enabled: ActiveModel::Type::Boolean.new.cast(params[:envelope][:rollover_enabled]))
        @envelope.propagate_rollover_choice_forward!
      end

      # Ruling 5: all-or-nothing — BOTH keys must be present (same rule as the
      # web controller), so a lone key can never write a half-target.
      if params.require(:envelope).key?(:target_type) && params.require(:envelope).key?(:target_amount)
        @envelope.update!(target_params)
        @envelope.propagate_target_choice_forward!
      end
    end

    # Ruling M4a-L3c: the recompute runs AFTER the writes commit, never inside
    # the transaction — RolloverCalculator takes a transaction-scoped advisory
    # lock, and acquiring it while update_budgeted_spending!'s row locks are
    # held inverts the lock order (Architecture: "after those transactions
    # commit — never inside them"; Global Constraints: advisory-lock order) and
    # deadlocks two concurrent writes on one rollover chain.
    Budget::Recalculate.call(family: @envelope.budget.family, budget: @envelope.budget)
    @envelope.budget.sync_budgeted_spending!

    @envelope.reload
    render :show
  rescue ActiveRecord::RecordInvalid => e
    # Ruling M4a-L3: the reachable failure here is a validation error
    # (BudgetCategory::InvalidMove is not raised by these paths); 422 matches
    # BudgetCategoriesController#update.
    render_validation_error(e.message)
  end

  def destroy
    budget = @envelope.budget
    # Ruling M4-L2 (2026-10-10 close-out): a parent whose children hold their
    # own allocations is refused. Its stored figure already contains those
    # children (M4a's Budget#assigned_total), so destroying it silently
    # double-counts them -- RTA overstated -- and the row reappears at 0 on
    # the month's next bootstrap, so the old 200 "deleted" contract was false.
    # No cascade, no silent money moves: the caller must move or clear the
    # children first.
    if @envelope.subcategories.reject(&:inherits_parent_budget?).any?
      return render_validation_error("Move or clear its children first")
    end

    @envelope.destroy!
    Budget::Recalculate.call(family: budget.family, budget: budget)
    budget.sync_budgeted_spending!
    # Ruling M4-L2: the family category is durable; only the month's derived
    # row goes, and it returns at 0 on the month's next bootstrap. The message
    # states the contract the response actually honours.
    render_json({ message: "Envelope cleared for this month" }, status: :ok)
  end

  private
    def ensure_read_scope = authorize_scope!(:read)
    def ensure_write_scope = authorize_scope!(:write)

    # Ruling M4a-L3: a read_only BudgetShare is a 404 on write, like the web.
    def ensure_budget_writable
      raise ActiveRecord::RecordNotFound unless @envelope.budget.editable_by?(current_resource_owner)
    end

    # Ruling M4a-L3: the sibling budget_categories API's exact refresh, so the
    # API never serves a stale rolled_over_amount/available_to_spend.
    # Ruling M4-L7 (2026-10-10 close-out): the fourth and last legacy
    # RolloverCalculator caller now routes through Budget::Recalculate like the
    # sibling's swap, so this read also recomputes credit envelopes and no
    # direct construction of the calculator remains outside the seam (pinned by
    # test/models/budget/recalculate_test.rb).
    def refresh_rollover_chains
      visible_owner_ids.each do |owner_id|
        budget = Budget
          .where(family: current_resource_owner.family, user_id: owner_id)
          .order(start_date: :desc)
          .first
        next unless budget

        Budget::Recalculate.call(family: current_resource_owner.family, budget: budget)
      end
    end

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
