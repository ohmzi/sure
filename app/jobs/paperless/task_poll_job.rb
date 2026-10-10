# frozen_string_literal: true

# One poll tick for a document link whose paperless task id is known. Polling is
# the GUARANTEED path (the workflow webhook is speculative, spec §8.1/§15.1), so
# this job reschedules itself with exponential backoff until the task settles.
# Every write is a guarded transition, so a late result can never clobber a row
# the user already linked.
class Paperless::TaskPollJob < ApplicationJob
  queue_as :default

  POLL_INTERVAL = 3.seconds
  MAX_INTERVAL  = 30.seconds
  MAX_ATTEMPTS  = 40

  discard_on ActiveRecord::RecordNotFound

  def perform(document_link_id)
    link = DocumentLink.find(document_link_id)
    return unless link.status == "processing" && link.paperless_task_id.present?

    attempts = link.poll_attempts.to_i + 1
    link.note_poll!(attempts)

    task = Paperless.client.task(link.paperless_task_id)

    case task.status
    when :success
      finish(link, task)
    when :pending, :started
      reschedule(link, attempts)
    end
  rescue Paperless::Error => e
    case e.code
    when :task_failed
      link.fail!(e.message)
    when :unauthorized
      Paperless.note_token_invalid!
      link.hold!(message: "paperless rejected the API token")
    else # unreachable, bad_response
      reschedule(link, attempts)
    end
  end

  private

    def finish(link, task)
      document_id = task.document_id || task.duplicate_of
      if document_id.blank?
        link.fail!("paperless reported success with no document id")
      elsif DocumentLink.where.not(id: link.id).exists?(paperless_document_id: document_id)
        link.fail!("duplicate of an already-filed document #{document_id}")
      else
        path = link.staged_path
        if link.finish_processing!(document_id: document_id)
          DocumentLink::Staging.delete(path)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      link.fail!("duplicate of an already-filed document")
    end

    def reschedule(link, attempts)
      if attempts >= MAX_ATTEMPTS
        link.hold!(message: nil) # keep bytes, clear task id: retryable
      else
        wait = [ POLL_INTERVAL * (2**(attempts - 1)), MAX_INTERVAL ].min
        self.class.set(wait: wait).perform_later(link.id)
      end
    end
end
