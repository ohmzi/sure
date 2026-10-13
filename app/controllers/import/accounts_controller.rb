# frozen_string_literal: true

# Confirm the account an import defaults to. It was the document wizard's screen
# 3; the wizard (steps 1-2 and its controller) is deleted, so this survives as
# the import flow's own account-confirm screen, reached from an import's review
# screen. ReceiptImport writes the column; PdfImport goes through M2's
# assign_account!, which also moves the statement.
class Import::AccountsController < ApplicationController
  include ImportAccountTeacher

  before_action :set_import
  before_action :require_non_guest!
  # (Ruling M7-L7, 2026-10-11 close-out) A statement-backed move re-targets the
  # STATEMENT (PdfImport#assign_account! -> AccountStatement#link_to_account!)
  # and unwinds the reconciliations it holds on the account being left, so the
  # caller must hold the statement's CURRENT-account permission BEFORE the move
  # — the same precondition ImportsController enforces for its own statement
  # mutations (require_statement_import_permission! / Ruling M2-L4's
  # manageable_by?). Without it, any family member who could write the TARGET
  # account could move a statement off an account they cannot manage.
  before_action :require_statement_import_permission!, only: :update

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

    # Spec N14's learned half. This screen is an assent line (with
    # ImportsController#update's inline select): the user has just confirmed
    # which account the document belongs to, so that account may learn the card
    # identity the read reported. Fill-only, and gated on the read's last4
    # witness — see Account#learn_card_identity. The write-back does NOT fire
    # where the guess was merely made (the read/resolver), so an unconfirmed
    # match can never become durable identity.
    teach_account(account)

    # (Owner decision 2026-10-11, hotfix; the intake hotfix's shape, re-applied
    # on this lane by M8 Task 9) the intake is fire-and-forget: land the user on
    # the archive, where the document appears immediately with its live status,
    # instead of the blocking "Reading your document" screen. A statement lands
    # on the statements-filtered archive so it is visible there too.
    destination = @import.is_a?(PdfImport) ? documents_path(source: "statement") : documents_path
    redirect_to destination, notice: t("imports.update.reading_in_background")
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    # The ImportsController guard, mirrored for the wizard's own refusal target.
    def require_statement_import_permission!
      return if @import.account_statement.blank? || @import.account_statement.manageable_by?(Current.user)

      redirect_back_or_to import_path(@import), alert: t("accounts.not_authorized")
    end
end
