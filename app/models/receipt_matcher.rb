# Link-only receipt ↔ transaction matcher (D8). It reads a DocumentLink's
# stored OCR snapshot, gathers candidate entries and scores them; it never
# creates, edits or links an entry — the user's tap does that
# (DocumentLink#link_to_entry!). Every return value is a value object.
class ReceiptMatcher
  # ±3 days, matching PdfImport::RECONCILIATION_DATE_WINDOW (app/models/pdf_import.rb:461).
  DATE_WINDOW = 3

  # `viewer` scopes candidate gathering to the accounts that viewer can access
  # (Account.accessible_by — the same model the accounts and transactions
  # surfaces use); it defaults to Current.user, so an inbox render can never
  # return candidates the current user cannot see. The cron job runs with no
  # Current.user and passes `viewer: nil` explicitly, keeping its family-wide
  # sweep. (Ruling M3-C2, 2026-10-11 close-out)
  def self.call(document_link, viewer: Current.user)
    new(document_link, viewer: viewer).call
  end

  def initialize(document_link, viewer: nil)
    @document_link = document_link
    @viewer = viewer
  end

  def call
    extraction = ReceiptMatcher::Extractor.call(ocr_text)
    return no_match if extraction.nil?

    date = document_date(extraction)
    candidates = rank(gather(extraction, date), extraction, date)
    return no_match if candidates.empty?

    build_result(candidates)
  end

  private
    def ocr_text
      @document_link.extracted_text.to_s
    end

    # Prefer the date printed on the receipt; fall back to when the link was
    # created. All real facts, never an inferred one.
    def document_date(extraction)
      extraction.date || @document_link.created_at.to_date
    end

    # Candidates: transaction entries on the family's active accounts, in each
    # account's own currency, for the exact extracted amount, dated within the
    # ±3-day window. A viewer narrows the accounts to those they can access
    # (owner or AccountShare) — the same merge Current#accessible_entries uses
    # (app/models/current.rb:31-34); nil (the cron job, which runs with no
    # Current.user) keeps the family-wide sweep.
    # (Ruling M3-C2, 2026-10-11 close-out)
    def gather(extraction, date)
      scope = Entry
        .joins(:account)
        .where(accounts: { family_id: @document_link.family_id, status: %w[active draft] })
        .where(entryable_type: "Transaction")
        .where("entries.currency = accounts.currency")
        .where(amount: extraction.amount)
        .where(date: (date - DATE_WINDOW)..(date + DATE_WINDOW))

      @viewer ? scope.merge(Account.accessible_by(@viewer)) : scope
    end

    def rank(entries, extraction, date)
      entries.map do |entry|
        distance = (entry.date - date).abs
        similarity = ReceiptMatcher::PayeeSimilarity.call(extraction.payee, entry.name)

        ReceiptMatcher::Candidate.new(
          entry: entry,
          day_distance: distance,
          payee_similarity: similarity,
          exact_amount: entry.amount == extraction.amount,
          score: score(distance, similarity)
        )
      end.sort_by(&:rank_key)
    end

    def score(day_distance, payee_similarity)
      value = 60 +
              ((DATE_WINDOW - day_distance).to_f / DATE_WINDOW * 25).round +
              (payee_similarity * 15).round
      value.clamp(0, 100)
    end

    # One unique best (by date then payee) is high-confidence → :suggested; a tie
    # for the top spot is ambiguous → :pending_review. This mirrors
    # Entry.reconcile_pending_duplicates's "only suggest if there's exactly ONE
    # matching candidate" rule (app/models/entry.rb:166, :244).
    def build_result(candidates)
      best = candidates.first
      tied = candidates.count do |candidate|
        candidate.day_distance == best.day_distance &&
          (candidate.payee_similarity - best.payee_similarity).round(2).zero?
      end

      ReceiptMatcher::Result.new(status: tied == 1 ? :suggested : :pending_review, candidates: candidates)
    end

    def no_match
      ReceiptMatcher::Result.new(status: :no_match)
    end
end
