# frozen_string_literal: true

# The hourly sweep for documents whose read never finished.
#
# A worker killed by an OOM or a rolling deploy leaves a row in `processing`
# with nothing scheduled to move it. The native read needs its own reaper, or a
# document is lost in the one way that looks like nothing happened.
#
# The cadence IS the retry bound: a row that is genuinely unreadable is retried
# once an hour, which is cheap and self-limiting (a successful read settles the
# row and drops it out of the scope).
class DocumentReaperJob < ApplicationJob
  queue_as :default

  BOUND = 30.minutes

  def perform
    stale = DocumentLink.stranded(before: BOUND.ago)
    count = stale.count
    stale.find_each { |link| DocumentUnderstandingJob.perform_later(link.id) }
    count
  end
end
