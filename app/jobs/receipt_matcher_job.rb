# Cron entry point (config/schedule.yml key `receipt_matcher`). Re-scores
# document links that are still waiting for a match — `unlinked` (never scored)
# and `suggested` (scored, not yet acted on). `dismissed`, `linked`, `verified`
# and `failed` rows are never selected, so a dismissal is remembered forever and
# a dismissed receipt is never re-suggested. Link-only (D8): the matcher writes
# no entries or amounts.
class ReceiptMatcherJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  MATCHABLE_STATUSES = %w[unlinked suggested].freeze

  def perform(family_id = nil)
    if family_id.nil?
      fan_out
    else
      match_for_family(family_id)
    end
  end

  private
    def fan_out
      DocumentLink.where(status: MATCHABLE_STATUSES).distinct.pluck(:family_id).each do |family_id|
        self.class.perform_later(family_id)
      end
    end

    def match_for_family(family_id)
      DocumentLink.where(family_id: family_id, status: MATCHABLE_STATUSES).find_each do |link|
        begin
          # viewer: nil — the job runs with no Current.user and scores the
          # family-wide candidate set for every member (Ruling M3-C2,
          # 2026-10-11 close-out): the suggestion state is family-level; each
          # member's inbox then scopes the rendered candidates per viewer.
          result = ReceiptMatcher.call(link, viewer: nil)
        rescue Paperless::Error
          # One paperless outage must not abort the remaining links; leave this
          # row for the next tick. (Ruling P-m3-1, 2026-10-10 pre-flight)
          next
        end
        next if result.no_match?

        # M1's guarded, atomic write (R4): a user dismiss/link racing this write
        # wins — the transition returns false rather than clobbering the row.
        link.record_match!(status: result.status.to_s, confidence: result.best.score)
      end
    end
end
