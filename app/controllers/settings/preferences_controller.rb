class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
  end

  # Writes per-user preferences: the JSONB `users.preferences` booleans and the
  # `users.default_account_id` FK (M7 locked decision 5 — the select card on the
  # Preferences page). Mirrors Settings::AppearancesController#update so the
  # toggle card can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled, :default_account_id, :dashboard_category_id ]).fetch(:user, {})

    if user_params.key?(:default_account_id)
      account = default_account_param(user_params[:default_account_id])
      return redirect_to settings_preferences_path, alert: t("accounts.set_default.depository_only") if account == :invalid
    end

    dashboard_category = nil
    if user_params[:dashboard_category_id].present?
      dashboard_category = Current.family.categories.find_by(id: user_params[:dashboard_category_id])
      return redirect_to settings_preferences_path, alert: t("settings.preferences.show.dashboard_category.invalid") if dashboard_category.nil?
    end

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      if user_params.key?(:dashboard_category_id)
        updated_prefs["dashboard_category_id"] = dashboard_category&.id
      end
      @user.assign_attributes(preferences: updated_prefs)
      @user.default_account = account if user_params.key?(:default_account_id)
      @user.save!
    end
    redirect_to settings_preferences_path
  end

  private
    # nil clears; nil-return-with-:invalid refuses. Visibility + the same
    # eligibility gate the star menu enforces (accounts_controller.rb:227-241).
    def default_account_param(raw)
      return nil if raw.blank?

      account = Current.user.accessible_accounts.visible.find_by(id: raw)
      return :invalid unless account&.eligible_for_transaction_default?

      account
    end
end
