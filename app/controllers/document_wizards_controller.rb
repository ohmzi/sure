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
      redirect_to import_path(draft) # Task 5 re-points this at the account-confirm step
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

    # INTERIM (Task 8 replaces this branch): the statement file takes M1's
    # document path as a statement. Task 8 creates the vault AccountStatement +
    # PdfImport (image-capable, locked decision 9) and hands off to M2's
    # StatementOcrJob instead.
    def create_statement
      file = wizard_file or return
      DocumentLink::Intake.call(family: Current.family, uploader: Current.user, file: file, source: "statement")
      redirect_to documents_path(source: "statement"), notice: t(".statement_queued")
    rescue DocumentLink::Intake::Duplicate
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".duplicate")
    rescue DocumentLink::Staging::TooLargeError
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".too_large")
    end
end
