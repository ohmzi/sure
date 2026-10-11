# frozen_string_literal: true

# Posts a DocumentLink's staged bytes to paperless, resolves tag names to PKs,
# records the task id and hands off to Paperless::TaskPollJob. On an unreachable
# host or a rejected token it KEEPS the staged bytes and returns the row to
# `queued` (never lost, never a retry loop, spec §8.1/§8.6). On a task failure it
# keeps the bytes and marks the row `failed` for the retry route.
class Paperless::UploadJob < ApplicationJob
  queue_as :high_priority

  POLL_DELAY = 3.seconds

  discard_on ActiveRecord::RecordNotFound

  def perform(document_link_id)
    link = DocumentLink.find(document_link_id)
    # Ruling M4 (M1), 2026-10-10 close-out: a duplicate delivery (a Sidekiq
    # retry, or a re-driven row) must not post the same bytes twice — the first
    # run already recorded the task id, and the poll owns the row from there.
    return if link.paperless_task_id.present?
    return if link.staged_path.blank?

    client = Paperless.client
    unless client.configured?
      link.hold!(message: nil)
      return
    end

    link.mark_processing!
    tag_ids = [ Paperless.tag_id("ohmzbudget"), Paperless.tag_id(link.source) ].compact

    task_id = link.staged_io do |io|
      client.post_document(io: io, filename: link.original_filename, content_type: link.content_type,
                           title: link.title, created: link.created_at, tags: tag_ids)
    end
    return link.fail!("staged upload is missing") if task_id.blank?

    link.record_task!(task_id)
    Paperless::TaskPollJob.set(wait: POLL_DELAY).perform_later(link.id)
  rescue Paperless::Error => e
    case e.code
    when :unreachable, :bad_response
      link.hold!(message: nil)
    when :unauthorized
      Paperless.note_token_invalid!
      link.hold!(message: "paperless rejected the API token")
    when :task_failed, :not_found
      link.fail!(e.message)
    end
  end
end
