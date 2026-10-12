# frozen_string_literal: true

# The document wizard's step 2 (M7): the quick-intake drop screen behind the
# home New popup's two document rows. Step 3 (Import::AccountsController) is
# only reached when the account prefill ladder cannot resolve (M8 Task 9,
# Ruling M8-L1 decision 2); otherwise the wizard finishes on the archive and
# must never block on OCR (locked decision 11).
class DocumentWizardsController < ApplicationController
  WIZARD_SOURCES = %w[receipt_or_bill statement].freeze
  # document_links.source is receipt|bill|statement|other. Under the Receipt or
  # Bill tile only the receipt/bill pair is legal: a statement-shaped filename
  # is clamped (the tile choice is the stronger signal, locked decision 12);
  # the one-tap receipt<->bill override now lives on the drop screen (M8
  # Task 9) and is clamped by the same pair.
  RECEIPT_BILL_SOURCES = %w[receipt bill].freeze

  before_action :require_non_guest!

  def new
    @source = wizard_source
    # The drop screen's form targets the WHOLE page (`_top`) when the ladder
    # resolves — the finish is then a full-page archive landing, not a swap of
    # the #modal frame; the ambiguous case keeps the modal for step 3
    # (Rendered into the #modal frame via the DS::Dialog container).
    @finish_immediately = Import::AccountPrefill.call(user: Current.user).account.present?
  end

  def create
    case wizard_source
    when "statement" then create_statement
    else create_receipt_or_bill
    end
  end

  private
    def wizard_source
      WIZARD_SOURCES.include?(params[:source].presence) ? params[:source] : "receipt_or_bill"
    end

    # M1 Ruling 6: two same-named file fields would merge into an Array and 500
    # params.require. The camera and upload rows post distinct names; exactly
    # one may be present.
    def wizard_file
      file = params[:document_camera].presence || params[:document_file].presence
      render(plain: "missing file", status: :unprocessable_entity) if file.blank?
      file
    end

    def create_receipt_or_bill
      file = wizard_file or return
      # Add details' title (M8 Task 9) is column-limited like the archive's:
      # 500 characters is the document_links.title cap, checked up front so a
      # hand-rolled POST can never reach the staged UPDATE.
      if params[:title].to_s.length > DocumentLinksController::MAX_TITLE_LENGTH
        return redirect_to new_document_wizard_path(source: wizard_source), alert: t(".invalid_file")
      end

      link = DocumentLink::Intake.call(family: Current.family, uploader: Current.user, file: file,
                                       source: receipt_bill_source(file), title: params[:title].presence)
      draft = ReceiptImport.create_from_document_link!(document_link: link)
      finish_or_ask(draft, destination: documents_path, notice: t(".reading_in_background"))
    rescue DocumentLink::Intake::Duplicate
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".duplicate")
    rescue DocumentLink::Staging::TooLargeError
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".too_large")
    rescue DocumentLink::Intake::InvalidSource, DocumentLink::Intake::FilenameTooLong
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".invalid_file")
    end

    # The one-tap override wins over the filename heuristic; anything outside
    # the receipt/bill pair falls back to the guess, clamped (a crafted
    # override can never smuggle a statement in under this tile).
    def receipt_bill_source(file)
      override = params[:source_override].to_s
      return override if RECEIPT_BILL_SOURCES.include?(override)

      guess = DocumentLink::SourceGuesser.guess(filename: file.original_filename,
                                                content_type: file.content_type).to_s
      RECEIPT_BILL_SOURCES.include?(guess) ? guess : "receipt"
    end

    # The skip-when-resolved ladder (M8 Task 9, Ruling M8-L1 decision 2):
    # Import::AccountPrefill.call is the ONE decision point — when it resolves
    # (an eligible default, or exactly one accessible account), the wizard
    # applies it and finishes on the archive (the 2026-10-11 hotfix's shape);
    # only the ambiguous case asks at step 3. A refusal from the move itself
    # (assign_account!'s guards) also falls back to the ask, never a 500.
    def finish_or_ask(import, destination:, notice:)
      account = Import::AccountPrefill.call(user: Current.user).account
      applied = account && (import.is_a?(PdfImport) ? import.assign_account!(account) : import.update(account: account))
      return redirect_to destination, notice: notice if applied

      redirect_to import_account_path(import) # step 3; the wizard ends there (locked decision 11)
    end

    def create_statement
      unless AccountStatement.statement_manager?(Current.user)
        return redirect_to new_document_wizard_path(source: "statement"), alert: t(".not_authorized")
      end

      file = wizard_file or return
      # (Ruling M7-L6, 2026-10-11 Task 8) the wizard's statement leg reads PDFs and
      # photos. A CSV/OFX/XLSX is VAULT-legal but not wizard-legal - there is no
      # scan to OCR and no template to match - and
      # PdfImport#account_statement_matches_import rightly refuses it, so refuse it
      # HERE, before anything is archived, and point the user at the Import flow
      # instead of raising RecordInvalid (which surfaced as a 500 with the file
      # already archived, and crashed identically on retry).
      unless statement_wizard_upload?(file)
        return redirect_to new_document_wizard_path(source: "statement"), alert: t(".unsupported_type")
      end

      pdf_import = PdfImport.create_from_upload!(family: Current.family, file: file, user: Current.user)
      outcome = PdfImport.route_processing_later!(pdf_import, file: file)
      # (Ruling M7-L6) the seam reports a failed OCR enqueue; the wizard must
      # surface it honestly rather than pretend the read started.
      return redirect_to import_path(pdf_import), alert: t(".statement_ocr_enqueue_failed") if outcome == :ocr_enqueue_failed

      # The same ladder decides (M8 Task 9): resolved finishes on the
      # statements-filtered archive; ambiguous asks at step 3. OCR settles
      # asynchronously (Ruling M7-L5, 2026-10-11 Task 8).
      finish_or_ask(pdf_import, destination: documents_path(source: "statement"), notice: t(".statement_processing"))
    rescue AccountStatement::DuplicateUploadError
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".duplicate")
    rescue AccountStatement::InvalidUploadError
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".invalid_file")
    rescue ActiveRecord::RecordInvalid
      # (Ruling M7-L6) backstop: if the vault's allow-list and the wizard's set ever
      # diverge, the user gets the honest refusal, never a 500 over a half-written row.
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".unsupported_type")
    end

    # The statement wizard accepts exactly what the OCR path can read.
    def statement_wizard_upload?(file)
      type = file.respond_to?(:content_type) ? file.content_type.to_s : ""
      type == "application/pdf" || type.start_with?("image/")
    end
end
