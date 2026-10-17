# frozen_string_literal: true

# The durable sweep for documents whose read never finished, or whose transient
# retry is due.
#
# A worker killed by an OOM or a rolling deploy leaves a row in `processing`
# with nothing scheduled to move it; a reboot can lose every queued job. The
# DocumentLink row is the source of truth, so this sweep resumes from the
# database. It runs every five minutes and once on Sidekiq startup.
#
# `DocumentLink.stranded` draws the boundaries: a live lease, a retry that is
# not due yet, a terminal hold and a row with no bytes are all left alone. The
# job's atomic claim makes a duplicate sweep harmless.
class DocumentReaperJob < ApplicationJob
  queue_as :default

  BOUND = 30.minutes

  # deploy/healthcheck-alert.sh compares this timestamp against the sweep
  # interval. A reaper that stops enqueueing leaves no other visible failure.
  HEARTBEAT_KEY = "sure:document_reaper:last_run"

  def perform
    # A deploy/reboot replaces the Sidekiq process that owned a read. Resume
    # those rows at once rather than waiting out the lease; a live-but-hung
    # process is still covered by the lease sweep below.
    recovered = DocumentLink.recover_orphaned_processing!

    stale = DocumentLink.stranded(before: BOUND.ago)
    count = stale.count
    stale.find_each { |link| DocumentUnderstandingJob.perform_later(link.id) }
    if (count + recovered).positive?
      Rails.logger.info("[DocumentReaper] Recovered #{recovered} orphaned read(s), resumed #{count} document(s)")
    end
    record_heartbeat
    count + recovered
  end

  private
    # The sweep's work matters more than its liveness signal: a monitor that
    # cannot read Redis is the monitor's problem, not a reason to fail a read.
    def record_heartbeat
      Sidekiq.redis { |redis| redis.set(HEARTBEAT_KEY, Time.current.to_i) }
    rescue StandardError => e
      Rails.logger.warn("[DocumentReaper] Could not record heartbeat: #{e.class}: #{e.message}")
    end
end
