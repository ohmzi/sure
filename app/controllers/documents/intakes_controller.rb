# frozen_string_literal: true

# The ONLY upload endpoint (design: one dropzone). It answers a document upload
# with a Turbo Stream that appends the new row, so the grid shows the document
# the instant it is chosen and the reader flips that same row in place when it
# settles — there is no wizard screen and no page change anywhere in this flow.
#
# RB1: until Task 3 lands the tile and the grid, the appended partial is the
# EXISTING document_browser/row (the row factory and partial M8 already ship, so
# the flow is complete and testable on its own). Task 3 swaps this one partial
# name to the tile.
class Documents::IntakesController < ApplicationController
  # Guests are read-only by design, and the other document-upload path
  # (DocumentLinksController#create) refuses them — the intake must not be the
  # one door left open.
  before_action :require_non_guest!, only: :create

  def create
    file = params[:document]
    return head :bad_request if file.blank?

    result = DocumentIntake.call(family: Current.family, uploader: Current.user, file: file)

    case result.kind
    when :document then render_row(result.record)
    when :csv, :ofx then redirect_to import_destination(result)
    else render_error(result.message)
    end
  rescue DocumentLink::Intake::Duplicate
    render_error(t(".duplicate"))
  rescue DocumentLink::Intake::FilenameTooLong, DocumentLink::Staging::TooLargeError
    render_error(t(".invalid_file"))
  end

  private
    def render_row(link)
      row = DocumentBrowser::Row.for_document_link(link, viewer_url: viewer_document_path(link))
      render turbo_stream: turbo_stream.append(
        "documents_grid", partial: "document_browser/row", locals: { row: row }
      ), status: :ok
    end

    def render_error(message)
      render turbo_stream: turbo_stream.update(
        "documents_intake_status", html: message.to_s
      ), status: :unprocessable_content
    end

    def import_destination(result)
      result.kind == :ofx ? import_upload_path(result.record) : import_configuration_path(result.record)
    end
end
