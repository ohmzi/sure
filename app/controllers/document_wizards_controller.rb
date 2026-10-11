# frozen_string_literal: true

# The document wizard's step 2 (M7): the camera/upload screen behind the home
# New popup's two document rows. Step 3 is Import::AccountsController; the
# wizard ENDS there and must never block on OCR (locked decision 11).
class DocumentWizardsController < ApplicationController
  WIZARD_SOURCES = %w[receipt_or_bill statement].freeze
  # document_links.source is receipt|bill|statement|other. Under the Receipt or
  # Bill tile only the receipt/bill pair is legal: a statement-shaped filename
  # is clamped (the tile choice is the stronger signal, locked decision 12);
  # the one-tap receipt<->bill override lives on the review screen (Task 7).
  RECEIPT_BILL_SOURCES = %w[receipt bill].freeze

  before_action :require_non_guest!

  def new
    @source = wizard_source
    # Rendered into the #modal frame via the DS::Dialog container (step 2 of 3).
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
      link = DocumentLink::Intake.call(family: Current.family, uploader: Current.user, file: file,
                                       source: receipt_bill_source(file))
      draft = ReceiptImport.create_from_document_link!(document_link: link)
      redirect_to import_account_path(draft) # step 3; the wizard ends there (locked decision 11)
    rescue DocumentLink::Intake::Duplicate
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".duplicate")
    rescue DocumentLink::Staging::TooLargeError
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".too_large")
    rescue DocumentLink::Intake::InvalidSource, DocumentLink::Intake::FilenameTooLong
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".invalid_file")
    end

    def receipt_bill_source(file)
      guess = DocumentLink::SourceGuesser.guess(filename: file.original_filename,
                                                content_type: file.content_type).to_s
      RECEIPT_BILL_SOURCES.include?(guess) ? guess : "receipt"
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

      redirect_to import_account_path(pdf_import), notice: t(".statement_processing") # step 3; OCR settles asynchronously (Ruling M7-L5, 2026-10-11 Task 8)
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
