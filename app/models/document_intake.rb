# frozen_string_literal: true

# One dropzone, no type question (spec N11). The file is inspected and routed: a
# scan or photo goes to the native pipeline, a bank export goes to the import
# pipeline that already knows how to read it, and anything else is refused with a
# message rather than fed to an OCR engine that cannot help.
#
# Detection is by CONTENT, never by filename. A bank exporting its ledger as
# `.pdf` and a scanner saving a PDF as `.txt` are both real.
class DocumentIntake
  Routed = Data.define(:kind, :record, :message)

  IMAGE_TYPES = %w[image/png image/jpeg image/webp image/heic image/heif].freeze
  PDF_TYPE = "application/pdf"
  # A PDF's magic number. This — not the MIME the browser guessed from the
  # name — is what tells a real PDF from a bank's CSV ledger exported as
  # `statement.pdf` with an `application/pdf` content type.
  PDF_SIGNATURE = "%PDF-"
  SPREADSHEET_TYPES = %w[
    text/csv application/csv text/plain
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  ].freeze
  SNIFF_BYTES = 8.kilobytes
  OFX_HEADER = /\AOFXHEADER|\A[^\n]*<OFX>/i

  def self.call(family:, uploader:, file:, title: nil)
    new(family:, uploader:, file:, title:).call
  end

  def initialize(family:, uploader:, file:, title:)
    @family = family
    @uploader = uploader
    @file = file
    @title = title
  end

  def call
    case classify
    when :ofx then route_ofx
    when :csv then route_csv
    when :document then route_document
    else Routed.new(kind: :rejected, record: nil, message: I18n.t("document_intake.rejected"))
    end
  end

  private
    # Read once, from the top, and rewind: every branch needs the same bytes and
    # none may consume the stream ahead of the next.
    def head
      @head ||= begin
        @file.tempfile.rewind
        bytes = @file.tempfile.read(SNIFF_BYTES).to_s
        @file.tempfile.rewind
        bytes
      end
    end

    # Content, not the name. An image is trusted by its MIME (the browser has
    # sniffed the photo), a PDF only when its `%PDF-` magic is really in the
    # bytes; a tabular first line is a bank export whatever the MIME claims, and
    # a spreadsheet MIME is accepted outright (its bytes are not text we can
    # cheaply sniff).
    def classify
      return :document if document_content?
      return :ofx if head.match?(OFX_HEADER)
      return :csv if looks_tabular?(head) || SPREADSHEET_TYPES.include?(content_type)

      :rejected
    end

    # An image, or a PDF whose signature is in the bytes — the latter regardless
    # of the MIME, so a scanned statement saved as `.txt` still reaches OCR.
    def document_content?
      IMAGE_TYPES.include?(content_type) || head.start_with?(PDF_SIGNATURE)
    end

    # A bank export's first line is its header row; two or more delimiters on it
    # is the cheapest signal that survives quoting and BOMs.
    def looks_tabular?(bytes) = bytes.lines.first.to_s.count(",;\t") >= 2

    def content_type = @file.content_type.to_s

    def route_document
      link = DocumentLink::Intake.call(
        family: @family, uploader: @uploader, file: @file, source: nil, title: @title,
        enqueue: ->(l) { DocumentUnderstandingJob.perform_later(l.id) }
      )
      Routed.new(kind: :document, record: link, message: nil)
    end

    # Reuse the two-step the app already has rather than inventing a third path:
    # an OfxImport is created here and the caller sends the user to the existing
    # upload screen, which is where the account is asked for — the ONE thing the
    # importer genuinely cannot infer.
    def route_ofx
      import = OfxImport.create!(family: @family, status: :pending, date_format: @family.date_format)
      Routed.new(kind: :ofx, record: import, message: nil)
    end

    def route_csv
      import = TransactionImport.create!(family: @family, status: :pending, date_format: @family.date_format)
      Routed.new(kind: :csv, record: import, message: nil)
    end
end
