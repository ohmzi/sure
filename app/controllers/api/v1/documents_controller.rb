# frozen_string_literal: true

# JSON upload surface for native clients. It runs the SAME router as the web
# dropzone (DocumentIntake), so content detection, the native read, the size
# cap and digest dedup cannot drift between the two clients. The differences
# are the contract, not the pipeline: this answers JSON (never a Turbo Stream)
# and refuses bank exports, which belong to the existing imports API.
class Api::V1::DocumentsController < Api::V1::BaseController
  before_action :ensure_write_scope
  # Guests are read-only by design; the web intake refuses them too.
  before_action :reject_guest_uploads

  def create
    file = params[:file]
    return render_missing_file unless file.respond_to?(:tempfile) && file.respond_to?(:original_filename)

    result = DocumentIntake.call(
      family: current_resource_owner.family,
      uploader: current_resource_owner,
      file: file,
      currency: DocumentIntake.currency_code(params[:currency]),
      documents_only: true
    )

    return render_document(result.record) if result.kind == :document

    render_json({ error: "invalid_file_type", message: result.message }, status: :unprocessable_entity)
  rescue DocumentLink::Intake::Duplicate
    render_json(
      { error: "duplicate_document", message: I18n.t("documents.intakes.create.duplicate") },
      status: :unprocessable_entity
    )
  rescue DocumentLink::Intake::FilenameTooLong
    render_json(
      { error: "invalid_file_name", message: I18n.t("documents.intakes.create.invalid_file") },
      status: :unprocessable_entity
    )
  rescue DocumentLink::Staging::TooLargeError
    render_json(
      {
        error: "file_too_large",
        message: "File is too large. Maximum size is #{DocumentLink::Staging::MAX_BYTES / 1.megabyte}MB."
      },
      status: :content_too_large
    )
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def reject_guest_uploads
      return unless current_resource_owner&.guest?

      render_json({ error: "forbidden", message: "Guests cannot upload documents" }, status: :forbidden)
    end

    def render_missing_file
      render_json(
        { error: "missing_file", message: "Attach the document as a multipart 'file' field." },
        status: :unprocessable_entity
      )
    end

    # The read is enqueued and the document is processing, so 202 is the honest
    # status: the upload is accepted, not finished.
    def render_document(link)
      render_json({ document: serialize(link) }, status: :accepted)
    end

    def serialize(link)
      {
        id: link.id,
        status: link.status,
        source: link.source,
        original_filename: link.original_filename,
        content_type: link.content_type,
        currency: link.currency,
        created_at: link.created_at.iso8601
      }
    end
end
