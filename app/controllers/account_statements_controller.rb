# frozen_string_literal: true

class AccountStatementsController < ApplicationController
  include DocumentBrowser
  # A statement's PDF import was read from a document, so confirming its account
  # here is the SAME assent line Import::AccountsController and ImportsController
  # hold: the account may learn its card identity from the read (spec N14).
  include ImportAccountTeacher

  before_action :set_statement, only: %i[show viewer update destroy link unlink reject review]
  before_action :ensure_statement_manager!, only: %i[index create update destroy link unlink reject review]

  def index
    @filters = document_browser_filters
    @pagy, @statements = pagy(account_statement_search.relation, limit: safe_per_page(20))
    # The viewer URL carries the page's query string (M8 locked decision 3), so
    # the modal's prev/next recompute over the same filtered list.
    @rows = @statements.map { |statement| DocumentBrowser::Row.for_account_statement(statement, viewer_url: viewer_account_statement_path(statement, document_browser_viewer_params)) }
    # The tag facet's choices: the archived links' stored snapshots (M8 Task 6),
    # narrowed to the statements this user may see — the same visible scope as
    # the list, never a live external call.
    @tag_choices = DocumentLink.tag_snapshot_names(
      Current.family.document_links.where(account_statement_id: visible_storage_scope.select(:id))
    )
    @total_storage_bytes = visible_storage_scope.sum(:byte_size)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("account_statements.index.title"), account_statements_path ]
    ]
    # The Statements page is a first-class destination now (M8 locked decision
    # 1): default layout, no settings chrome. One list over the vault's
    # per-user visible scope — the unmatched/linked split is replaced by the
    # review/extraction facets (locked decision 9). (Milestone B, design D1:
    # the page's own upload form is gone — the Documents dropzone is the one
    # way in — so the account select it carried is gone too.)
  end

  # GET /account_statements/:id/viewer — the modal (M8 Task 4). Prev/next
  # recompute over the SAME filtered visible relation the index listed, so the
  # walk can never desync from the list.
  def viewer
    # The modal does not link to itself: the row presenter is built without a
    # viewer_url here (that field exists for the index rows).
    @row = DocumentBrowser::Row.for_account_statement(@statement)
    previous_statement, next_statement = document_browser_neighbours(@statement)
    @previous_url = previous_statement && viewer_account_statement_path(previous_statement, document_browser_viewer_params)
    @previous_title = previous_statement && statement_display_title(previous_statement)
    @next_url = next_statement && viewer_account_statement_path(next_statement, document_browser_viewer_params)
    @next_title = next_statement && statement_display_title(next_statement)
    # The view lives with the rest of the page (see the index note above).
    render "account_statements/viewer"
  end

  def show
    @accounts = Current.user.accessible_accounts.visible.alphabetically
    @can_manage_statement = @statement.manageable_by?(Current.user)
    @reconciliation_checks = @statement.reconciliation_checks
    @overlap_mismatches = @statement.overlapping_balance_mismatches
    @imported_rows_count = Entry.reconciled_by(@statement).count
    @statement_imports_count = @statement.pdf_imports.count
    @delete_blocked_message = deletion_blocker_message(@statement)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("account_statements.index.title"), account_statements_path ],
      [ @statement.filename, nil ]
    ]
    # (Ruling M8-C5, 2026-10-11 close-out) the vault's drill-through stays on
    # the main chrome too — the owner asked the pages not to change location,
    # and a row's Details jumped from the main Statements page into settings.
  end

  def create
    files = Array(statement_upload_params[:files]).reject(&:blank?).select { |file| file.respond_to?(:read) }
    account = target_account

    if files.empty?
      redirect_back_or_to account_statements_path, alert: t("account_statements.create.no_files")
      return
    end

    return if account && !require_account_permission!(account)

    created = []
    duplicates = []
    validation_errors = []

    files.each do |file|
      prepared_upload = AccountStatement.prepare_upload!(file)
      statement = AccountStatement.create_from_prepared_upload!(family: Current.family, account: account, prepared_upload: prepared_upload)
      # The unified Documents page reads DocumentLink; without this the account
      # tab's own upload would be invisible where documents live (Task 3, Step 7).
      statement.archive_document_link!(uploader: Current.user, process: true)
      created << statement
    rescue AccountStatement::InvalidUploadError
      validation_errors << t("account_statements.create.invalid_file_type")
    rescue AccountStatement::DuplicateUploadError => e
      # A duplicate upload is also the user's chance to restore a document their
      # duplicate review deleted. Keep the surviving statement's existing link
      # when one is live; otherwise archive its stored bytes again.
      e.statement.archive_document_link!(uploader: Current.user) if e.statement.original_file.attached?
      duplicates << e.statement
    rescue ActiveRecord::RecordInvalid => e
      validation_errors << e.record.errors.full_messages.to_sentence
    end

    redirect_to redirect_after_create(account, created.first || duplicates.first),
                flash_for_upload(created:, duplicates:, validation_errors:)
  end

  def update
    return if @statement.account && !require_account_permission!(@statement.account)

    target = statement_account_id.present? ? Current.user.accessible_accounts.find(statement_account_id) : nil
    return if target && !require_account_permission!(target)

    attrs = statement_params.to_h
    attrs[:account] = target if statement_account_id_provided?

    @statement.assign_attributes(attrs)
    @statement.assign_account_match if @statement.account.nil? && !@statement.rejected?

    if @statement.save
      redirect_to account_statement_path(@statement), notice: t("account_statements.update.success")
    else
      @accounts = Current.user.accessible_accounts.visible.alphabetically
      @can_manage_statement = @statement.manageable_by?(Current.user)
      @reconciliation_checks = @statement.reconciliation_checks
      @overlap_mismatches = @statement.overlapping_balance_mismatches
      @imported_rows_count = Entry.reconciled_by(@statement).count
      @statement_imports_count = @statement.pdf_imports.count
      @delete_blocked_message = deletion_blocker_message(@statement)
      flash.now[:alert] = @statement.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  def link
    return if @statement.account && !require_account_permission!(@statement.account)

    account_id = params[:account_id].presence || @statement.suggested_account_id
    if account_id.blank?
      redirect_to account_statement_path(@statement), alert: t("account_statements.link.no_account")
      return
    end

    account = Current.user.accessible_accounts.find(account_id)
    return unless require_account_permission!(account)

    # A refused assignment must NOT report success: the statement is still
    # unlinked, and telling the user otherwise is a silent lie about
    # money-adjacent state. `assign_account!` refuses when the import is no
    # longer re-targetable — its data already landed, or a publish/revert holds
    # the row — so the copy stays general rather than promising a retry.
    unless assign_statement_account(account)
      redirect_to account_statement_path(@statement), alert: t("account_statements.link.account_locked")
      return
    end

    notice = if @published_import
      t("account_statements.link.imported", account: account.name, count: @published_import.rows_count)
    else
      t("account_statements.link.success", account: account.name)
    end
    redirect_to post_link_path(@statement), notice: notice
  end

  def unlink
    return if @statement.account && !require_account_permission!(@statement.account)

    @statement.unlink!
    redirect_to account_statement_path(@statement), notice: t("account_statements.unlink.success")
  end

  def reject
    return if @statement.account && !require_account_permission!(@statement.account)

    @statement.reject_match!
    redirect_to account_statements_path, notice: t("account_statements.reject.success")
  end

  # A person has checked this statement by hand. The reconciliation checks are
  # facts and stay visible; this records that a human looked at them.
  def review
    return if @statement.account && !require_account_permission!(@statement.account)

    @statement.update!(reviewed_at: Time.current, reviewed_by: Current.user)
    redirect_back_or_to account_statement_path(@statement), notice: t("account_statements.review.success")
  end

  def destroy
    return if @statement.account && !require_account_permission!(@statement.account)

    redirect_path = @statement.account ? account_path(@statement.account, tab: "statements") : account_statements_path
    if (message = deletion_blocker_message(@statement))
      redirect_to redirect_path, alert: message
      return
    end

    # The statement and its archived document are one artifact, but their
    # deletion cannot be one rollback: clearing the document's bytes is
    # filesystem work that a DB rollback cannot undo. So the statement's own
    # delete (under its row lock, with the `restrict_with_error` guards) is
    # guaranteed FIRST, and only then may the document give up its bytes. If a
    # PdfImport lands after the blocker read, the destroy fails and rolls back
    # with the bytes still on disk — the old order deleted them and left a
    # byte-less duplicate on re-upload.
    refusal = nil
    destroyed = @statement.transaction do
      @statement.lock!

      if (message = deletion_blocker_message(@statement))
        refusal = message
        raise ActiveRecord::Rollback
      end

      document_link = @statement.archived_document_link
      unless @statement.destroy
        # A concurrent writer (a PdfImport, say) can land between the blocker
        # read and the delete; the restrict guard is the authoritative refusal.
        refusal = deletion_blocker_message(@statement) || t("account_statements.destroy.failure")
        raise ActiveRecord::Rollback
      end

      # The statement delete is now guaranteed. A refusal here (an unreconciled
      # entry appeared in the meantime) rolls the statement back and keeps the
      # bytes; `soft_delete!` returns false instead of raising.
      unless document_link.nil? || document_link.soft_delete!
        refusal = t("account_statements.destroy.document_blocked",
                    entries: document_link.deletion_blockers.to_sentence)
        raise ActiveRecord::Rollback
      end

      true
    end

    if destroyed
      redirect_to redirect_path, notice: t("account_statements.destroy.success")
    else
      redirect_back_or_to redirect_path, alert: refusal || t("account_statements.destroy.failure")
    end
  end

  private

    def account_statement_search
      AccountStatement::Search.new(user: Current.user, family: Current.family, filters: document_browser_filters)
    end

    # The walk is recomputed server-side over the same filtered visible
    # relation the index listed (M8 locked decision 3): pagination can never
    # desync it. A stale URL whose row is not visible renders no neighbours.
    def document_browser_neighbours(statement)
      account_statement_search.neighbours(statement)
    end

    def statement_display_title(statement) = statement.filename

    # The vault's per-user visible scope (M8 Task 3): the storage figure covers
    # exactly the statements the signed-in user may see.
    def visible_storage_scope
      Current.family.account_statements
        .where(account_id: nil)
        .or(Current.family.account_statements.where(account_id: Current.user.accessible_accounts.select(:id)))
    end

    def deletion_blocker_message(statement)
      case statement.deletion_blocker
      when :document
        t("account_statements.destroy.document_blocked",
          entries: statement.archived_document_link.deletion_blockers.to_sentence)
      when :imports
        imported_rows = Entry.reconciled_by(statement).count
        if imported_rows.positive?
          t("account_statements.destroy.imported_rows", count: imported_rows)
        else
          t("account_statements.destroy.pending_import")
        end
      end
    end

    def set_statement
      @statement = Current.family.account_statements
        .with_attached_original_file
        .includes(:account, :suggested_account, :archived_document_link)
        .find(params[:id])

      raise ActiveRecord::RecordNotFound unless @statement.viewable_by?(Current.user)
    end

    def ensure_statement_manager!
      return if AccountStatement.statement_manager?(Current.user)

      redirect_to accounts_path, alert: t("accounts.not_authorized")
    end

    def statement_upload_params
      params.fetch(:account_statement, ActionController::Parameters.new).permit(files: [])
    end

    def statement_params
      params.require(:account_statement).permit(
        :institution_name_hint,
        :account_name_hint,
        :account_last4_hint,
        :period_start_on,
        :period_end_on,
        :opening_balance,
        :closing_balance,
        :currency
      )
    end

    def target_account
      account_id = statement_account_id.presence
      return nil if account_id.blank?

      Current.user.accessible_accounts.find(account_id)
    end

    def statement_account_id
      params.fetch(:account_statement, ActionController::Parameters.new)[:account_id]
    end

    def statement_account_id_provided?
      params.fetch(:account_statement, ActionController::Parameters.new).key?(:account_id)
    end

    def redirect_after_create(account, statement = nil)
      if account
        account_path(account, tab: "statements")
      elsif statement
        account_statement_path(statement)
      else
        account_statements_path
      end
    end

    def post_link_path(statement)
      statement.account ? account_path(statement.account, tab: "statements") : account_statement_path(statement)
    end

    # The statement's account is assigned through the SAME seam the import
    # review screen uses (spec N14): a PDF import's `assign_account!` moves BOTH
    # the import and this statement — the import keeps winning publishes and its
    # rows stay judged against the right account. The account then LEARNS its
    # card identity from the read (ImportAccountTeacher#teach_account), the same
    # fill-only, OCR-witnessed write the /imports/:id confirmation makes; without
    # it the account's last4/account_network stayed blank on this surface. A
    # statement with no import to re-target (a CSV/OFX vault row) takes the
    # statement-only writer.
    #
    # Returns false when the import refuses (no longer re-targetable under its
    # lock) so the caller can surface it instead of a false success.
    def assign_statement_account(account)
      import = @statement.latest_reusable_pdf_import

      if import
        @import = import
        return false unless import.assign_account!(account)

        teach_account(account)
        @published_import = import if publish_if_reconciled(import)
      else
        @statement.link_to_account!(account)
        teach_account(account, @statement.archived_document_link&.extraction)
      end

      # The import seam moves a SEPARATE AccountStatement instance, so reload to
      # read the account the redirect below keys off.
      @statement.reload
      true
    end

    def flash_for_upload(created:, duplicates:, validation_errors: [])
      alerts = []
      alerts << t("account_statements.create.duplicates", count: duplicates.size) if duplicates.any?
      alerts.concat(validation_errors.compact_blank)

      if created.any?
        flash = { notice: t("account_statements.create.success", count: created.size) }
        flash[:alert] = alerts.to_sentence if alerts.any?
        flash
      else
        { alert: alerts.to_sentence }
      end
    end
end
