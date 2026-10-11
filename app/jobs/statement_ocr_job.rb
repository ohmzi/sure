# frozen_string_literal: true

require "stringio"

# The paperless-OCR statement path (spec §8.2, §8.6). The archived statement PDF
# is posted through M1's DocumentLink spine (source: "statement"), the OCR task
# is polled with a bounded re-schedule, and the OCR text is read from
# Paperless::Document#content (R2) — the archive PDF's own text layer is the
# fallback only when that content is blank. A deterministic StatementTemplate
# then turns the text into rows; an unknown bank is archived in the explicit
# needs_template state (never guessed at), and every paperless failure resets the
# statement's extraction_state so a crash can never wedge it (R8).
class StatementOcrJob < ApplicationJob
  queue_as :medium_priority

  POLL_WAIT = 15.seconds
  STALE_AFTER = 30.minutes
  MAX_RESCHEDULES = 5

  discard_on(ActiveRecord::RecordNotFound)

  def perform(pdf_import_id)
    import = PdfImport.find(pdf_import_id)
    return unless import.pending? && import.statement_backed?

    statement = import.account_statement
    link = statement_link(statement, import)

    # Keyed on the LINK, not the statement: after a failed post the link holds no
    # task id, so a retry re-posts instead of reading a nil document. The link is
    # the spine's memory, so no `processing?` guard can wedge us. Transitions go
    # through update_all, so the ids are carried in locals, never the stale
    # in-memory link.
    task_id = link.paperless_task_id
    if task_id.blank? && link.paperless_document_id.blank?
      return fail_extraction(statement, link, :paperless_not_configured) unless client.configured?

      statement.update!(extraction_state: :processing)
      link.mark_processing!
      task_id = client.post_document(
        io: StringIO.new(import.pdf_file_content),
        filename: import.pdf_filename,
        content_type: "application/pdf",
        title: import.pdf_filename,
        created: Time.current,
        tags: [ Paperless.tag_id("statement") ]
      )
      link.record_task!(task_id)
    end

    document_id = link.paperless_document_id
    if task_id.present?
      task = client.task(task_id)

      case task.status
      when :pending, :started
        return fail_extraction(statement, link, :paperless_timed_out) if link.updated_at < STALE_AFTER.ago

        return self.class.set(wait: POLL_WAIT).perform_later(pdf_import_id)
      when :failure # belt-and-braces; M1's #task raises :task_failed instead
        return fail_extraction(statement, link, :paperless_task_failed, detail: task.error_message)
      when :success
        # (Ruling M2-C1, 2026-10-11 close-out) M1's TaskPollJob precedent
        # (paperless/task_poll_job.rb:47): paperless reports a duplicate upload
        # as success with a nil document_id and duplicate_of set. Reading only
        # document_id stranded such a statement in extraction_failed with no
        # way out; adopt the duplicate's document and settle the statement
        # normally.
        document_id = task.document_id || task.duplicate_of
        link.finish_processing!(document_id: document_id)
      end
    end

    text = ocr_text(document_id)
    template = StatementTemplate.detect(text)

    if template.nil?
      statement.update!(extraction_state: :needs_template)
      return
    end

    apply_template(statement, import, template, text)
  rescue Paperless::Error => e
    handle_paperless_error(statement, link, e, pdf_import_id)
  end

  private

    def client
      @client ||= Paperless::Client.new
    end

    # Reuse the statement's link across retries; create it via M1's factory.
    def statement_link(statement, import)
      DocumentLink.where(family: statement.family, account_statement_id: statement.id, source: "statement").first ||
        begin
          created = DocumentLink.link_from_upload!(
            family: statement.family, uploader: nil, source: "statement", title: import.pdf_filename
          )
          created.update!(account_statement_id: statement.id)
          created
        end
    end

    # R2: the paperless document's OCR `content` is the primary text source; the
    # archive PDF's text layer is read only when that content is blank.
    def ocr_text(document_id)
      content = client.document(document_id).content.to_s
      return content if content.present?

      chunks = +""
      client.file(document_id, kind: :preview) { |chunk, _env| chunks << chunk }
      PDF::Reader.new(StringIO.new(chunks)).pages.map(&:text).join("\n")
    end

    def apply_template(statement, import, template, text)
      rows = template.rows(text)

      # A detected template that matches no line is still "we could not read
      # this": never report success with zero rows (spec §8.6).
      if rows.empty?
        statement.update!(extraction_state: :needs_template)
        return
      end

      import.update!(
        document_type: "bank_statement",
        # The publish gate (PdfImport#configured? = ai_processed? && rows_count > 0)
        # reads ai_summary; setting it deterministically makes the template path
        # reviewable instead of dead-ending on the clean screen.
        ai_summary: I18n.t("imports.statement_ocr.summary", bank: template.bank_key, version: template.version),
        extracted_data: {
          "transactions" => rows.map do |row|
            { "date" => row.date.to_s, "amount" => row.amount.to_s("F"), "name" => row.payee.to_s, "notes" => row.memo.to_s, "category" => "" }
          end
        }
      )
      import.generate_rows_from_extracted_data
      import.sync_mappings
      statement.update!(extraction_state: :extracted)
      import.update!(status: import.rows_count.positive? ? :pending : :complete)
    end

    def fail_extraction(statement, link, key, detail: nil)
      link&.transition!(from: %w[queued processing failed], to: "failed", failure_message: key.to_s, paperless_task_id: nil)
      statement.update!(extraction_state: :extraction_failed)
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "StatementOcrJob failure: #{key}#{detail.present? ? " (#{detail})" : ""}",
        source: "statement_ocr_job",
        family: statement.family,
        metadata: { account_statement_id: statement.id, reason: key.to_s }
      )
    end

    def handle_paperless_error(statement, link, error, pdf_import_id)
      case error.code
      when :unauthorized
        Paperless.note_token_invalid!
        fail_extraction(statement, link, :paperless_unauthorized, detail: error.message)
      when :task_failed, :not_found
        fail_extraction(statement, link, :"paperless_#{error.code}", detail: error.message)
      when :unreachable, :bad_response
        reschedule_or_fail(statement, link, error, pdf_import_id)
      else
        fail_extraction(statement, link, :paperless_error, detail: error.message)
      end
    end

    # Bounded re-schedule for transient paperless errors (R8): count the attempt
    # on the link and, past the bound, settle terminally as extraction_failed.
    def reschedule_or_fail(statement, link, error, pdf_import_id)
      attempts = link.poll_attempts.to_i + 1
      if attempts > MAX_RESCHEDULES
        return fail_extraction(statement, link, :"paperless_#{error.code}", detail: error.message)
      end

      link.mark_processing!
      link.note_poll!(attempts)
      self.class.set(wait: POLL_WAIT).perform_later(pdf_import_id)
    end
end
