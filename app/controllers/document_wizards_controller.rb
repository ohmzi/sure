# frozen_string_literal: true

# The document wizard's step 2 (M7): the quick-intake drop screen behind the
# home New popup's two document rows. Both legs now stage the link, enqueue the
# native DocumentUnderstandingJob and land on the archive: the receipt/bill leg
# since Task 8, the statement leg since Task 9. The account-prefill ladder no
# longer runs here at all — it moves into the read pipeline in Task 10, and the
# step-3 ask route it can hand off to stays live for that move. The wizard must
# never block on OCR (locked decision 11).
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
    # The drop screen's form always targets the WHOLE page (`_top`): the finish
    # is a full-page archive landing, never a swap of the #modal frame. The
    # step-3 ask the modal once served is gone — both legs hand the staged link
    # to the native read and settle on the archive.
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

      # The link is staged and the native read owns everything after it (Task 8):
      # DocumentUnderstandingJob is the enqueued job, so no document is read
      # twice. The draft is created by the JOB once it has a verdict, so the
      # wizard no longer creates one here — and the account prefill ladder moves
      # into the pipeline in a later task, so this path finishes on the archive
      # (the step-3 ask is now the statement path's alone until then).
      DocumentLink::Intake.call(
        family: Current.family, uploader: Current.user, file: file,
        source: receipt_bill_source, title: params[:title].presence,
        enqueue: ->(link) { DocumentUnderstandingJob.perform_later(link.id) }
      )
      redirect_to documents_path, notice: t(".reading_in_background")
    rescue DocumentLink::Intake::Duplicate
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".duplicate")
    rescue DocumentLink::Staging::TooLargeError
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".too_large")
    rescue DocumentLink::Intake::InvalidSource, DocumentLink::Intake::FilenameTooLong
      redirect_to new_document_wizard_path(source: wizard_source), alert: t(".invalid_file")
    end

    # The one-tap override wins; anything outside the receipt/bill pair (or no
    # override) files as a receipt. The read's DocumentClassifier owns the real
    # class once the bytes are read, so this is only the initial hint.
    def receipt_bill_source
      override = params[:source_override].to_s
      RECEIPT_BILL_SOURCES.include?(override) ? override : "receipt"
    end

    # The skip-when-resolved ladder (M8 Task 9, Ruling M8-L1 decision 2):
    # Import::AccountPrefill.call is the ONE decision point — when it resolves
    # (an eligible default, or exactly one accessible account), the wizard
    # applies it and finishes on the archive (the 2026-10-11 hotfix's shape);
    # only the ambiguous case asks at step 3. A refusal from the move itself
    # (assign_account!'s guards) also falls back to the ask, never a 500.
    #
    # STILL DEAD CODE, and Task 10 confirmed it stays so. Its old comment
    # predicted the ladder would "return to the pipeline" here, but Task 10 put
    # the account resolver INSIDE DocumentUnderstandingJob
    # (Account::DocumentMatcher + resolve_account), where the draft is made and
    # the AI hints are in hand — not in the controller, which no longer holds an
    # import at drop time (Task 9 removed the statement leg's synchronous
    # import). So no caller came back and none was added just to have one.
    # Retained deliberately, not deleted silently: the step-3 ask route this
    # redirects to (`import_account_path`) is live, and Import::AccountPrefill is
    # still the ladder that step-2's `#new` and that ask screen's select ride on.
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
      # The Add details title is column-limited like the archive's (500 is
      # document_links.title's cap). This leg's drop screen renders no title
      # field, so this guards a hand-rolled POST from reaching the staged INSERT
      # - the same guard, for the same reason, as create_receipt_or_bill.
      if params[:title].to_s.length > DocumentLinksController::MAX_TITLE_LENGTH
        return redirect_to new_document_wizard_path(source: "statement"), alert: t(".invalid_file")
      end

      # (Task 9) The statement leg is the native read's now, exactly as the
      # receipt leg became it in Task 8: the link is staged and
      # DocumentUnderstandingJob is enqueued, and the vault row and its PdfImport
      # are created BY the read once it has a verdict and its transactions. The
      # wizard creates nothing synchronously and enqueues no second pipeline, so
      # one document is never read twice — and with no import in hand there is
      # nothing for the account ladder to prefill, so this leg lands on the
      # archive (the ladder moves into the pipeline in Task 10).
      link = DocumentLink::Intake.call(
        family: Current.family, uploader: Current.user, file: file,
        source: "statement", title: params[:title].presence,
        enqueue: ->(l) { DocumentUnderstandingJob.perform_later(l.id) }
      )
      # Intake holds the row back to `queued` when the enqueue raised (Ruling 11,
      # and Ruling M7-L6 for this leg): the statement is archived and safe, but
      # the read never started, so the wizard must not promise one in the
      # background.
      if link.status == "queued"
        return redirect_to documents_path(source: "statement"), alert: t(".statement_ocr_enqueue_failed")
      end

      redirect_to documents_path(source: "statement"), notice: t(".statement_processing")
    rescue DocumentLink::Intake::Duplicate
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".duplicate")
    rescue DocumentLink::Staging::TooLargeError
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".too_large")
    rescue DocumentLink::Intake::InvalidSource, DocumentLink::Intake::FilenameTooLong
      redirect_to new_document_wizard_path(source: "statement"), alert: t(".invalid_file")
    end

    # The statement wizard accepts exactly what the OCR path can read.
    def statement_wizard_upload?(file)
      type = file.respond_to?(:content_type) ? file.content_type.to_s : ""
      type == "application/pdf" || type.start_with?("image/")
    end
end
