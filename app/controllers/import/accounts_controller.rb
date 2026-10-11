# frozen_string_literal: true

# The document wizard's screen 3: confirm the account an intake defaults to.
# Shared by both wizard legs (ReceiptImport writes the column; PdfImport goes
# through M2's assign_account!, which also moves the statement).
class Import::AccountsController < ApplicationController
  before_action :set_import
  before_action :require_non_guest!

  def show
    @accounts = Current.user.accessible_accounts.visible.alphabetically
    @prefill = Import::AccountPrefill.call(user: Current.user)
    # Rendered in the #modal frame through accounts/new/container (step 3 of 3).
  end

  def update
    account = Current.user.accessible_accounts.visible.find_by(id: params.dig(:import, :account_id))
    return redirect_back_or_to import_path(@import), alert: t("imports.update.invalid_account") unless account
    return if @import.account_statement.present? && !require_account_permission!(account)

    saved = @import.is_a?(PdfImport) ? @import.assign_account!(account) : @import.update(account: account)
    return redirect_back_or_to import_path(@import), alert: t("imports.update.account_locked") unless saved

    redirect_to import_path(@import), notice: t("imports.update.account_saved")
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end
end
