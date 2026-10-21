class Import::UploadsController < ApplicationController
  include ImportGuestGuardable

  layout "imports"

  before_action :set_import
  before_action :require_import_editable!, only: :update

  def show
  end

  def sample_csv
    send_data @import.csv_template.to_csv,
      filename: "#{@import.type.underscore.split('_').first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  end

  def update
    if @import.is_a?(QifImport)
      handle_qif_upload
    elsif @import.is_a?(OfxImport)
      handle_ofx_upload
    elsif @import.is_a?(SureImport)
      update_sure_import_upload
    elsif csv_valid?(csv_str)
      @import.account = import_account_id.present? ? accessible_accounts.find(import_account_id) : nil
      @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
      @import.save!(validate: false)

      redirect_to import_configuration_path(@import, template_hint: true), notice: t("imports.create.csv_uploaded")
    else
      flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")

      render :show, status: :unprocessable_entity
    end
  end

  private

    def update_sure_import_upload
      uploaded = upload_params[:ndjson_file]
      unless uploaded.present?
        flash.now[:alert] = t("import.uploads.sure_import.ndjson_invalid", default: "Must be valid NDJSON with at least one record")
        render :show, status: :unprocessable_entity
        return
      end

      if uploaded.size > SureImport.max_ndjson_size
        flash.now[:alert] = t("imports.create.file_too_large", max_size: SureImport.max_ndjson_size / 1.megabyte)
        render :show, status: :unprocessable_entity
        return
      end

      content = uploaded.read
      uploaded.rewind

      if ndjson_valid?(content)
        uploaded.rewind
        @import.ndjson_file.attach(uploaded)
        @import.sync_ndjson_rows_count!
        redirect_to import_path(@import), notice: t("imports.create.ndjson_uploaded")
      else
        flash.now[:alert] = t("import.uploads.sure_import.ndjson_invalid", default: "Must be valid NDJSON with at least one record")

        render :show, status: :unprocessable_entity
      end
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def handle_qif_upload
      unless QifParser.valid?(csv_str)
        flash.now[:alert] = "Must be a valid QIF file"
        render :show, status: :unprocessable_entity and return
      end

      normalized_qif = QifParser.normalize_encoding(csv_str)

      unless import_account_id.present? || QifParser.parse_accounts(normalized_qif).any?
        flash.now[:alert] = t(".qif_account_required")
        render :show, status: :unprocessable_entity and return
      end

      ActiveRecord::Base.transaction do
        @import.account = accessible_accounts.find(import_account_id) if import_account_id.present?
        @import.raw_file_str = normalized_qif
        @import.save!(validate: false)
        @import.generate_rows_from_csv
        @import.sync_mappings
      end

      redirect_to import_qif_category_selection_path(@import), notice: t(".qif_uploaded")
    end

    def handle_ofx_upload
      unless Ofx::Parser.valid?(csv_str)
        flash.now[:alert] = t(".ofx_invalid")
        return render :show, status: :unprocessable_entity
      end

      unless import_account_id.present?
        flash.now[:alert] = t(".ofx_account_required")
        return render :show, status: :unprocessable_entity
      end

      account = accessible_accounts.find(import_account_id)
      uploaded_file = upload_params[:import_file]
      normalized = Ofx::Parser.normalize_encoding(csv_str)
      duplicate = false
      statement = nil

      ActiveRecord::Base.transaction do
        @import.account = account
        @import.raw_file_str = normalized
        statement, duplicate = archive_ofx_statement(uploaded_file, account)
        @import.account_statement = statement
        @import.save!(validate: false)
        @import.generate_rows_from_csv
        @import.sync_mappings
      end

      # After the transaction commits — and only then. ActiveStorage defers the
      # blob write to the commit, so the statement's bytes are unreadable from
      # inside it; the unified Documents page's link is staged here, once the
      # bytes are on the service (Task 3, Step 7).
      #
      # The link stays on the STATEMENT only. An OFX/QFX bank export is an
      # "Import file", not a "Document" (spec §8.6), so the import must NOT carry
      # a document_link or its rows would read "from a document". The N9
      # delete-block reaches those rows through the statement instead --
      # DocumentLink#derived_entries follows `imports.account_statement_id`.
      statement.archive_document_link!(uploader: Current.user) if statement

      notice = duplicate ? t(".ofx_duplicate_notice") : t(".ofx_uploaded")
      redirect_to import_clean_path(@import), notice: notice
    rescue Ofx::Parser::ParseError, AccountStatement::InvalidUploadError
      # Empty, oversize, or a content type outside the extension allow-list:
      # create_from_upload! raises before anything is archived (the transaction
      # rolls back). Match the CSV branch's flash + 422 pattern rather than 500.
      # (Ruling M2-C3, 2026-10-11 close-out): a crafted document that passes
      # valid? but trips REXML's entity-expansion/security guards raises
      # ParseError from generate_rows_from_csv; the archive rolls back with the
      # rest of the transaction and the upload fails here too.
      flash.now[:alert] = t(".ofx_invalid")
      render :show, status: :unprocessable_entity
    end

    # The raw OFX file is archived in the Statement Vault for provenance. SHA-256
    # dedup is AccountStatement's own: a duplicate reuses the existing row and is
    # reported by the caller (spec §8.1 "a duplicate warns, never silently
    # re-adds"), never swallowed.
    def archive_ofx_statement(uploaded_file, account)
      return [ nil, false ] unless uploaded_file.respond_to?(:original_filename)

      uploaded_file.rewind if uploaded_file.respond_to?(:rewind)
      statement = AccountStatement.create_from_upload!(
        family: Current.family,
        account: account,
        file: uploaded_file
      )
      [ statement, false ]
    rescue AccountStatement::DuplicateUploadError => e
      [ e.statement, true ]
    end

    def csv_str
      @csv_str ||= upload_params[:import_file]&.read || upload_params[:raw_file_str]
    end

    def csv_valid?(str)
      begin
        csv = Import.parse_csv_str(str, col_sep: upload_params[:col_sep])
        return false if csv.headers.empty?
        return false if csv.count == 0
        true
      rescue CSV::MalformedCSVError
        false
      end
    end

    def ndjson_valid?(str)
      return false if str.blank?

      # Check at least first line is valid NDJSON
      first_line = str.lines.first&.strip
      return false if first_line.blank?

      begin
        record = JSON.parse(first_line)
        record.key?("type") && record.key?("data")
      rescue JSON::ParserError
        false
      end
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :import_file, :ndjson_file, :col_sep)
    end

    def import_account_id
      params.require(:import).permit(:account_id)[:account_id]
    end
end
