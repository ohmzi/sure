# frozen_string_literal: true

# The native read: one idempotent job per document.
#
# The read is one job: the OCR sidecar produces the text and the page images,
# and the AI provider reads the meaning from them, because both halves need the
# same thing: the pages.
class DocumentUnderstandingJob < ApplicationJob
  queue_as :heavy

  # Pages per provider call. ONE page per call is the correct default.
  #
  # A real 6-page Triangle Mastercard statement read with a 4-page batch came
  # back with 7 rows where a single page carried 28: a multi-page batch is
  # answered at a summary level, and raising the response-token cap changed
  # nothing, so a dense page's table is only enumerated when the model is given
  # that page alone. The price is deliberate: one call per page means a 40-page
  # statement is 40 provider calls (more time, more tokens), and that is the
  # cost of a correct read.
  #
  # Overridable by DOCUMENT_UNDERSTANDING_PAGE_BATCH for a deployment that has
  # MEASURED a larger batch that still enumerates a page fully. The default
  # stays 1 and the value is floored at 1; anything above 1 risks truncating a
  # dense page's table again.
  PAGE_BATCH = 1

  # The batch size to read at: the safe default, or the env override. Read at
  # call time (not cached) so a test or a deployment can pin it; a blank or
  # non-integer env value falls back to the constant, and it is floored at 1.
  def self.page_batch_size
    override = ENV["DOCUMENT_UNDERSTANDING_PAGE_BATCH"]
    return PAGE_BATCH if override.blank?

    [ Integer(override, exception: false) || PAGE_BATCH, 1 ].max
  end

  # The link's staged bytes in the shape the vault's own creation path reads:
  # AccountStatement.prepare_upload! asks an upload for original_filename,
  # content_type, read, rewind and size. Going through that path - rather than
  # re-implementing its checks - is what keeps the vault's invariants (filename,
  # content_type, checksum and byte_size present, an allowed extension/
  # content_type pair, the sniffed type, the digest) satisfied by the same code
  # that guards a user's own upload.
  StoredUpload = Data.define(:io, :original_filename, :content_type) do
    def read(*args) = io.read(*args)
    def rewind = io.rewind
    def size = io.size
  end

  # The bounded retry ladder for a transient failure. One constant drives both
  # the policy (`attempts:`) and the terminal copy, so "after N attempts" cannot
  # drift from how many attempts are actually configured.
  RETRY_ATTEMPTS = 8

  # An OCR failure is transient far more often than it is terminal — the sidecar
  # is restarting, the GPU is busy, the weights are still loading. Retry with
  # backoff; only a service that ANSWERED and said "unreadable" lands terminally.
  #
  # The block runs once the retries are SPENT and the sidecar is still
  # unreachable, and lands the row terminally with a message. Without it the row
  # would rest mid-read forever — invisible, and never re-driven. That silent
  # wedge is the predecessor's failure mode this milestone exists to remove.
  #
  # It uses abandon!, not fail! (fix round 2): during the backoff the row is
  # parked `queued` (await_retry!), so fail!'s `processing`-only guard would
  # no-op and leave a spent row parked forever.
  retry_on Ocr::Error, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS do |job, error|
    DocumentLink.find_by(id: job.arguments.first)&.abandon!(
      message: "OCR service unreachable after #{RETRY_ATTEMPTS} attempts: #{error.message}"
    )
  end

  # A provider failure is transient far more often than terminal (a blip, a 5xx,
  # a busy model), and the sweep no longer re-drives held rows (finding 2), so a
  # synchronous hold here would wait for a human forever. It joins the same
  # bounded retry ladder as an OCR blip instead (fix round 2, the transient
  # self-healing the reviewer flagged): parked during the backoff, then either a
  # successful read settles the row or the ladder is spent and abandon! lands it
  # terminally. Bounded by RETRY_ATTEMPTS.
  retry_on Provider::Error, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS do |job, error|
    DocumentLink.find_by(id: job.arguments.first)&.abandon!(
      message: "AI provider unavailable after #{RETRY_ATTEMPTS} attempts: #{error.message}"
    )
  end
  discard_on ActiveRecord::RecordNotFound

  # The user-facing wording for a read that produced nothing usable. Since
  # Ruling R14 a 422 from the sidecar means the service could not RENDER the
  # page (a corrupt file, a degenerate page) — not that the engine found no
  # text — so the message must say "could not be read", not "found no text".
  # The same sentence also covers the empty-200 read (no `pages` at all), where
  # there is no page to name; "document" is therefore the word that is right for
  # both paths. The `(code)` suffix the caller appends stays the diagnostic.
  UNREADABLE_MESSAGE = "This document could not be read".freeze
  NO_PROVIDER_MESSAGE = "no AI provider is configured".freeze

  # The deterministic cross-checks. Pure, so the review screen can call them and
  # so they are testable without a provider or a sidecar.
  def self.validate(understanding, ocr_text:)
    ai_total = understanding.total
    ocr_total = OcrTotal.call(ocr_text)

    # The SAME guarded parse the model's own total goes through (review finding
    # 2): before this, "12,34,5" parsed as 12345 here while `total` read it as
    # nil, so a model that also reported 12345 made the sum "agree" on a value
    # nobody could read — a false `true` on the key that gates auto-post.
    line_items = understanding.line_items.map { |i| DocumentUnderstanding.parse_amount(i["amount"]) }
    sum_ok =
      if understanding.line_items.empty? || ai_total.nil? || line_items.any?(&:nil?)
        # Nothing to check, or a line item the model sent unreadable — either
        # way the sum is NOT checkable. Never a false pass: this key gates a
        # later auto-post, so a wrong `true` is money-relevant.
        nil
      else
        line_items.sum == ai_total
      end

    last4 = [ understanding.account_last4, understanding.card_last4 ].compact
    {
      "totals_agree" => (ai_total.present? && ocr_total.present? ? ai_total == ocr_total : nil),
      "ai_total" => ai_total&.to_s("F"),
      "ocr_total" => ocr_total&.to_s("F"),
      "line_items_sum" => sum_ok,
      "last4_in_ocr" => last4.empty? ? nil : last4.any? { |digits| ocr_text.to_s.include?(digits) },
      "date_parses" => understanding.date.present?
    }
  end

  def perform(document_link_id)
    link = DocumentLink.find(document_link_id)

    # Idempotent: a re-delivery, or the reaper re-enqueueing, must be a no-op
    # once the read settled. `processing` is allowed so a crashed attempt resumes.
    return unless link.status.in?(%w[queued processing])

    link.mark_processing!

    return link.hold!(message: "no OCR service is configured") unless Ocr.configured?

    result = read(link)
    return land_unreadable(link, result.failure_code) if result.failure?
    # A genuine empty read (Task 3's client reads a body with no `pages` key as
    # a non-failure, empty result) is "nothing was understood": no text AND no
    # page images to send. Hold it for the user rather than settle a text-less
    # read. When the OCR found no text but DID render pages, those images are
    # exactly what the vision model is for — a text-less photo is the canonical
    # case, so forward them (Ruling R14).
    return land_unreadable(link, :no_text) if result.text.blank? && result.page_images.empty?

    link.record_content!(result.text, refresh: true)

    provider = Provider::Registry.preferred_llm_provider
    return link.hold!(message: NO_PROVIDER_MESSAGE) unless provider&.supports_document_understanding?

    # One provider call per batch of pages (Task 9). A 40-page statement sent as
    # one request hits the context and payload limits and fails hard, which is
    # the case this milestone exists for. A provider failure is transient far
    # more often than terminal, and a held row is excluded from the sweep
    # (finding 2), so it propagates to the retry_on Provider::Error ladder rather
    # than parking the row for a human (fix round 2).
    understanding = understand_in_batches(provider, result, link)

    validations = self.class.validate(understanding, ocr_text: result.text)
    classification = DocumentClassifier.call(
      ai_verdict: understanding, filename: link.original_filename,
      content_type: link.content_type, ocr_text: result.text
    )

    DocumentExtraction.record!(
      document_link: link,
      provider: provider.provider_name,
      model: provider.llm_model,
      ocr_engine: result.engine,
      page_count: result.pages.size,
      ocr_text: result.text.first(DocumentLink::EXTRACTED_TEXT_LIMIT),
      raw_response: understanding.to_verdict,
      verdict: understanding.to_verdict,
      field_confidence: understanding.field_confidence.to_h,
      validations: validations,
      status: "succeeded"
    )

    link.update!(page_count: result.pages.size, ocr_engine: result.engine,
                 ocr_finished_at: Time.current)
    link.classify!(document_class: classification.document_class,
                   confidence: classification.confidence,
                   classified_by: classification.classified_by,
                   corroborated: classification.corroborated)
    # Route while the link is still `processing` — settle! flips it to
    # `unlinked` immediately after, and link_to_entry! only accepts the
    # LINKABLE statuses (the routed draft is linked at PUBLISH, not here).
    # The OCR text rides along: the account resolver's last4 witness (§7.5) is
    # "the digits actually appear on the page", and validate already reads the
    # same text.
    route(link, understanding, classification, ocr_text: result.text)
    link.settle!
    link.broadcast_row_update!
  rescue Ocr::Error, Provider::Error => e
    # Transient upstream failure: let retry_on re-enqueue. Park the row `queued`
    # with the reason (fix round 2) so the sweep cannot select it during the
    # backoff — the later waits far exceed the sweep's bound, and a second read
    # would race this one. The retry still finds the row, and mark_processing!
    # clears the mark when it restarts, so a crash after the restart stays
    # sweepable.
    #
    # The user reads a sentence, never the exception (item 3, cleanup wave):
    # this reason stays on the row for the WHOLE backoff window, and `Ocr::Error`
    # carries raw upstream text verbatim on `:unreachable` / `:bad_response`
    # ("Failed to open TCP connection to ocr:9000 (Connection refused)"). The
    # reason is named per code; the raw text goes to the log.
    Rails.logger.warn(
      "DocumentUnderstandingJob retry scheduled for document_link #{document_link_id}: #{e.class}: #{e.message}"
    )
    link&.await_retry!(message: retry_message(e))
    raise
  rescue ActiveRecord::RecordNotFound
    # A vanished link is discarded (the `discard_on` above), never held: there is
    # no row to hold. Re-raised so `discard_on` still sees it.
    raise
  rescue => e
    # Anything else is ours: record it on the link so the archive can show it,
    # and STOP. This arm deliberately does NOT re-raise (review finding 1):
    # nothing matches `retry_on`, and Sidekiq's default is 25 attempts, so
    # re-raising re-entered through the job's own `queued` guard, cleared the
    # hold in `mark_processing!`, and re-ran the WHOLE read — the OCR sidecar
    # plus a paid provider call — on every attempt. That is the unbounded replay
    # Task 11's two fix rounds removed for the OCR and provider classes; here it
    # was reintroduced for every other exception (a route failure such as the
    # statement vault's DuplicateUploadError, a PG::UniqueViolation, a nil-method
    # bug). A generic exception is usually a bug, not a transient upstream blip,
    # so a bounded retry ladder would only burn more paid reads on a
    # deterministic failure. The row is held with its reason and recoverable
    # through `reprocess!`; a fresh read after that starts from a clean state.
    #
    # The exception goes to the LOG, never into the message the archive shows:
    # `failure_message` is rendered verbatim on the row, tile and panel, so
    # "read failed: ActiveRecord::RecordNotUnique: ..." or a
    # DuplicateUploadError's internals would put raw exception text in front of
    # the owner. The user gets one plain sentence; the detail lives in the log.
    Rails.logger.error(
      "DocumentUnderstandingJob read failed for document_link #{document_link_id}: #{e.class}: #{e.message}"
    )
    DocumentLink.find_by(id: document_link_id)&.hold!(message: "This document could not be read. Retry it from the archive.")
  end

  private
    # The transient-retry reason the user reads, chosen by error code — never
    # the raw exception text, which belongs in the log. Both the OCR codes the
    # client can raise and a provider failure get their own sentence.
    def retry_message(error)
      return "The AI provider is unavailable; a retry is scheduled." if error.is_a?(Provider::Error)

      case error.code
      when :not_configured then "The OCR service is not configured; a retry is scheduled."
      when :unreachable then "The OCR service is unreachable; a retry is scheduled."
      when :server_error then "The OCR service reported an error; a retry is scheduled."
      when :bad_response then "The OCR service returned an unexpected response; a retry is scheduled."
      else "This document could not be read; a retry is scheduled."
      end
    end

    def read(link)
      link.stored_io do |io|
        return Ocr.client.recognize(io: io, filename: link.original_filename.to_s,
                                    content_type: link.content_type.presence || "application/octet-stream",
                                    include_images: true)
      end
      # stored_io returns nil when the column is blank — a row with no bytes can
      # never settle, so fail it loudly instead of looping.
      raise "document has no stored bytes"
    end

    def land_unreadable(link, code)
      link.hold!(message: "#{UNREADABLE_MESSAGE} (#{code})")
    end

    # A RECEIPT draft that reached `understood` MAY post itself (spec N6) — the
    # gate, not this call, decides, and it re-checks at write time. Enqueued,
    # never run inline: the read settles first (link.settle! runs after route),
    # and the writer re-reads the draft and re-judges the gate, so a job that
    # trusted this caller would be one refactor away from writing money it
    # should not. Enqueued only when the household switch is on; off, the
    # reviewed publish is the only path that writes money.
    #
    # Only receipts, never bills (Ruling RB8). A receipt is evidence of payment —
    # if it exists, the money moved. A bill is an invoice that may be unpaid, so
    # auto-posting it would write an expense that never happened; a bill is read
    # and drafted, then waits for the one tap. The class comes from the
    # classification in hand, not from `link.source`: classify! writes the column
    # with a direct UPDATE, so the in-memory link's `source` is still stale here.
    def enqueue_auto_post(draft, document_class)
      return unless document_class == "receipt"
      return unless draft.understood?
      return unless Setting.auto_post_receipts?
      # A reprocess must not silently re-post money the user took back (the
      # carried-in Task 9 gap): the document remembers the reversal, and the gate
      # re-checks it at write time too -- this only avoids the dead enqueue.
      return if draft.document_link&.auto_post_undone?

      AutoPostReceiptJob.perform_later(draft.id)
    end

    # The money-adjacent seam: a receipt or a bill becomes a reviewable draft,
    # filled from the same three-method contract `apply_extraction!` has always
    # consumed. Nothing here writes money — the reviewed publish does that.
    # find_or_create (never create) because a retry, a reaper re-enqueue or a
    # reprocess must adopt the draft it already made, not mint a second set of
    # rows.
    def route(link, understanding, classification, ocr_text:)
      case classification.document_class
      when "receipt", "bill"
        draft = ReceiptImport.find_or_create_from_document_link!(document_link: link)
        draft.apply_extraction!(ReceiptImport::Understanding.new(understanding))
        # The row -> extraction anchor (spec §8.3): the draft traces to the read
        # that produced it. Written here, at the one seam that has both the
        # draft and its extraction in hand.
        draft.update!(document_extraction: link.extraction)
        enqueue_auto_post(draft, classification.document_class)
      when "statement"
        route_statement(link, understanding)
      else
        # "other": archived and deliberately not read for line items — the right
        # answer for a warranty or a lease. Nothing to route.
        nil
      end

      # Task 10: resolve the draft's account from the AI's hints, above the bar
      # only. Runs for every class; a class with no draft resolves to nil. The
      # OCR text rides along so the resolver can apply §7.5's last4 witness.
      resolve_account(link, understanding, ocr_text: ocr_text)
    end

    # Prefill only when the hints resolve to one account above the bar. Below it
    # nothing is written and the wizard's step-3 screen asks — which stays the
    # ONLY place a user is asked which account a document belongs to.
    #
    # This is NOT where an account learns its identity (Task 11). The write-back
    # fires at the human's confirmation (Import::AccountsController#update), and
    # cannot fire here even in principle: a prefill is the resolver's unconfirmed
    # guess, and teaching a blank account from it would launder that guess into
    # state the fill-only rule then makes permanent. The last4 term is GATED on
    # the OCR witness below, so a prefill can only name an account whose last4
    # ALREADY equals a number the page carries — never a fabricated one.
    #
    # The draft is found by whichever edge the leg created: a receipt/bill draft
    # (ReceiptImport) hangs off the document link, and the statement leg's
    # PdfImport now carries the document link too -- `create_from_statement!`
    # sets it to the statement's archived copy (spec N13). The `account_statement`
    # fallback remains for a statement row whose import predates that link and
    # has none to backfill (a statement with no archived document copy at all),
    # so a lookup by document_link alone would still miss such a statement.
    #
    # The last4 hint is the CARD's when the read reported one. The card number
    # ("7891" in the live Triangle read) is the document's card identity; the
    # account-number last4 ("7512") is a weaker, bank-side hint and only used
    # when no card number was read. Spec §7.5's second witness rides the chosen
    # hint: the digits must appear in the OCR text before the column match is
    # worth the prefill weight.
    def resolve_account(link, understanding, ocr_text:)
      last4_hint = understanding.card_last4.presence || understanding.account_last4
      witnessed = last4_hint.present? && ocr_text.to_s.include?(last4_hint.to_s)

      match = Account::DocumentMatcher.best_match(
        family: link.family,
        institution_hint: understanding.institution_name,
        account_last4_hint: last4_hint,
        card_network: understanding.card_network,
        currency: understanding.currency,
        last4_witness: witnessed
      )
      return nil if match.nil? || match.confidence < Account::DocumentMatcher::AUTO_PREFILL_BAR

      import = draft_for(link)
      return nil unless import

      # PdfImport#assign_account! runs its own reassignability guards and can
      # refuse; ReceiptImport takes a plain update. Either refusing is "no
      # prefill" — the step-3 ask picks it up — never an error.
      applied = import.is_a?(PdfImport) ? import.assign_account!(match.account) : import.update(account: match.account)
      applied ? match : nil
    end

    def draft_for(link)
      by_document = Import.where(document_link: link).order(created_at: :desc).first
      return by_document if by_document
      return nil if link.account_statement_id.blank?

      Import.where(account_statement_id: link.account_statement_id).order(created_at: :desc).first
    end

    # The statement seam: the document's own vault row plus a PdfImport holding
    # the statement's rows, in the state the review screen already knows how to
    # show. Nothing here writes money — the reviewed publish does that. Note that
    # the statement arrives with NO account: resolving one from the hints is
    # Task 10's job, so today an imported statement sits unmatched until the user
    # picks its account at the review step.
    def route_statement(link, understanding)
      # The intake no longer asks the user what a document is, so this guard has
      # nothing to test at staging time — it belongs where the vault row would be
      # created. Refusing here leaves the document read, archived and visible with
      # a reason, which is strictly better than the old tile's "not authorized"
      # redirect that discarded the upload outright.
      unless AccountStatement.statement_manager?(link.created_by)
        return link.hold!(message: I18n.t("documents.held.statement_permission"))
      end

      statement = statement_for(link, understanding)
      import = PdfImport.find_or_create_from_statement!(statement: statement)

      import.update!(
        account_statement: statement,
        document_type: "bank_statement",
        # The row -> extraction anchor (spec §8.3): the import traces to the read
        # that produced it. `source_page` on each transaction is carried through
        # to the generated Import::Row; it is only present when the batch that
        # read the row covered exactly one page.
        document_extraction: link.extraction,
        ai_summary: statement_summary(understanding),
        extracted_data: { "transactions" => understanding.transactions.map do |row|
          { "date" => row["date"].to_s, "amount" => row["amount"].to_s,
            "name" => row["name"].to_s, "notes" => row["notes"].to_s, "category" => "",
            "source_page" => row["source_page"] }
        end }
      )
      import.generate_rows_from_extracted_data
      import.sync_mappings
      statement.update!(extraction_state: :extracted)
      import.update!(status: import.rows_count.positive? ? :pending : :complete)
    end

    # What the review screen shows and the next-steps email carries. The AI read
    # this document, and the summary must stay present: Import#ai_processed? IS
    # `ai_summary.present?`, and the publish
    # gate reads it. The bank name is a hint the read may not have produced, so a
    # nameless statement gets the sentence without the parenthesis rather than an
    # empty "()".
    def statement_summary(understanding)
      bank = understanding.institution_name
      return I18n.t("imports.statement_read.summary_no_bank") if bank.blank?

      I18n.t("imports.statement_read.summary", bank: bank)
    end

    # The statement vault row for this document, created on first read and
    # adopted thereafter. Hints come from the verdict now, not from a filename.
    #
    # The row is built through AccountStatement's own creation path, never a bare
    # find_or_initialize_by(...).save!: the vault requires filename, content_type,
    # checksum and byte_size, an allowed extension/content_type pair and an
    # attached original_file, so a row that skips that path (or its sniffing)
    # cannot be saved at all. (Controller ruling R2.)
    def statement_for(link, understanding)
      statement = link.account_statement_id &&
                  link.family.account_statements.find_by(id: link.account_statement_id)
      statement ||= create_statement_vault_row(link)

      statement.assign_attributes(
        institution_name_hint: understanding.institution_name,
        # The CARD's last4, not the account number. The seeded identity and the
        # prefill both key on the card's number ("7891" in the live Triangle
        # read); storing the account number ("7512") made the vault matcher score
        # bank digits against a card column and produce no suggestion. Same
        # preference resolve_account applies.
        account_last4_hint: understanding.card_last4.presence || understanding.account_last4,
        # `currency`, not `statement_currency`: the latter is a reader on the
        # model (currency || account's || family's), not a column.
        currency: understanding.currency,
        period_start_on: understanding.period_start,
        period_end_on: understanding.period_end
      )
      # Offer the account suggestion now that the hints are on the row: the
      # vault matcher (AccountStatement::AccountMatcher) reads them, and without
      # this a statement the read could not confidently prefill would show the
      # page's "no suggestion" dead end until the user saves the metadata form.
      # A read that DOES prefill clears this at link time (link_to_account!).
      statement.assign_account_match if statement.account_id.nil? && !statement.rejected?
      statement.save! if statement.changed?
      link.update!(account_statement_id: statement.id) unless link.account_statement_id == statement.id
      statement
    end

    # The vault's own creator, fed the document's stored bytes: it validates the
    # upload, sniffs the real content type, computes the digest, attaches the
    # file, detects metadata and (with no account yet) offers an account match. A
    # file already in this family's vault is refused by that path, which is the
    # honest answer — the link is held visibly rather than a second row minted
    # for the same bytes.
    def create_statement_vault_row(link)
      # prepare_upload! must run INSIDE the block: Staging.open closes the file
      # when the block returns, and the prepared upload is the in-memory copy
      # everything after this point works from.
      prepared = nil
      link.stored_io do |io|
        prepared = AccountStatement.prepare_upload!(
          StoredUpload.new(io: io, original_filename: link.original_filename.to_s,
                           content_type: link.content_type.presence || "application/octet-stream")
        )
      end
      raise "document has no stored bytes" if prepared.nil?

      AccountStatement.create_from_prepared_upload!(
        family: link.family, account: nil, prepared_upload: prepared
      )
    end

    # Pages in bounded batches, stitched. The statement's identity fields (class,
    # institution, period) come from the first batch that reports them; the
    # transactions accumulate across every batch, because losing a later batch's
    # rows is the failure this design exists to prevent.
    #
    # The batches are cut from the PAGES rather than from the page images: a page
    # the OCR rendered no image for still carries text that must reach the model,
    # and cutting from `page_images` alone would send zero batches for a
    # text-only read and lose the whole document.
    def understand_in_batches(provider, result, link)
      merged = nil
      transactions = []
      line_items = []

      result.pages.each_slice(self.class.page_batch_size) do |pages|
        # The read's heartbeat (Task 11 fix round 1): a long multi-batch read
        # must keep its row fresh, or the reaper's staleness test would
        # re-enqueue it while it is still running — a second OCR run, a second
        # paid provider call, a second extraction.
        link.heartbeat!
        response = provider.understand_document(pages: pages.filter_map(&:image),
                                                ocr_text: batch_ocr_text(pages, merged),
                                                family: link.family)
        raise Provider::Error, "AI provider failed: #{response.error&.message}" unless response.success?

        part = response.data
        merged = merge_understanding(merged, part)
        # Rows and line items are the two fields that ACCUMULATE, and both are
        # read RAW here: a batch is not a document. A mid-statement run of
        # continuation pages routinely comes back classified "other" on the
        # generic no-schema read, and `part.transactions` — gated on that batch's
        # OWN class — dropped its rows silently. Same trap for a multi-page
        # receipt, whose items live beyond its first page while
        # merge_understanding keeps only the first value per field.
        # The row -> page anchor (spec §8.3). A batch is a slice of the read's
        # OCR pages, so a row belongs to those pages; only a SINGLE-page batch
        # names one page. One page per call is now the default, so the anchor is
        # set for every row in the usual case; a batch configured larger than one
        # page leaves the page unknown — the row could sit on any of its pages —
        # and an invented page would be a traceability lie, so it stays nil.
        # Coordinates are always nil: PaddleOCR's boxes are per recognised line
        # and are not linked to the model's transaction/item rows, so there is no
        # genuine box to record.
        page = pages.size == 1 ? pages.first.number : nil
        transactions.concat(tag_page(part.transaction_rows, page))
        line_items.concat(tag_page(part.line_items, page))
      end

      # The gate is therefore the MERGED verdict's class — the first batch that
      # reported one, which is also exactly what DocumentClassifier judges and
      # what `transactions` itself gates on, so a read that will be routed as a
      # statement always carries every batch's rows. Line items go on every read;
      # they are the receipt/bill leg's payload and the statement's reader ignores
      # them. A statement's row dates are re-anchored to its own period before
      # they are stitched in, so a yearless "Sep 20" lands in the period's year
      # and not a year the model invented.
      if merged.document_class == "statement"
        merged.with_transactions(normalise_statement_dates(transactions, merged))
              .with_line_items(line_items)
      else
        merged.with_line_items(line_items)
      end
    end

    # The OCR text a batch is sent, prefixed with the document's date context
    # once an earlier batch has resolved it. A continuation page's per-batch OCR
    # text carries no year, and the statement's period lives on page one, so
    # without this the model anchors a bare "Sep 20" to a year it invents (the
    # live Triangle read returned 2023 on a 2026 statement). The first batch has
    # no earlier context and needs none: the opening page carries the period.
    def batch_ocr_text(pages, merged)
      text = pages.map(&:text).join("\n\n")
      context = statement_date_context(merged)
      context.present? ? "#{context}\n\n#{text}" : text
    end

    # The date-context line for a later batch, or nil when there is nothing to
    # anchor — a non-statement, or a statement whose period is not yet known.
    def statement_date_context(merged)
      return nil unless merged&.document_class == "statement"

      start_on = merged.period_start
      end_on = merged.period_end
      return nil if start_on.nil? && end_on.nil?

      period = [ start_on, end_on ].compact.map(&:iso8601).join(" to ")
      "Statement date context: this statement covers #{period}. " \
        "A transaction date that does not state a year belongs to this period."
    end

    # Re-anchors each statement row's date to the document's own period. A row
    # date may omit the year (the batch OCR usually carries none) or name a year
    # the model guessed wrong; either way the period is the only honest anchor.
    # Nothing happens without a period (a receipt, or a statement that named
    # none), so a document with its own dates is never disturbed.
    def normalise_statement_dates(rows, merged)
      start_on = merged.period_start
      end_on = merged.period_end
      return rows if start_on.nil? && end_on.nil?

      rows.map do |row|
        date = reanchor_row_date(row["date"], start_on, end_on)
        date ? row.merge("date" => date) : row
      end
    end

    # The row's date with its year taken from the statement period, or nil when
    # there is nothing to do (an unreadable date, or a year already among the
    # period's own years — the model got it right and it is left as read). Only
    # a statement's rows reach here.
    def reanchor_row_date(value, start_on, end_on)
      parts = Date._parse(value.to_s)
      month = parts[:mon]
      day = parts[:mday]
      return nil if month.nil? || day.nil?

      years = [ start_on&.year, end_on&.year ].compact.uniq
      return nil if years.empty?
      return nil if parts[:year] && years.include?(parts[:year])

      # The period's end is the anchor: for a cycle that spans the new year it
      # picks the year the date actually falls in, not simply the start's.
      anchor = end_on || start_on
      year = years.min_by { |candidate| days_from(anchor, candidate, month, day) }
      Date.new(year, month, day).iso8601
    rescue Date::Error
      nil
    end

    # How far a (year, month, day) sits from the anchor; an impossible date
    # (Feb 30) is infinitely far so it can never be chosen.
    def days_from(anchor, year, month, day)
      (Date.new(year, month, day) - anchor).abs
    rescue Date::Error
      Float::INFINITY
    end

    # Stamps the batch's page onto each row when the batch named exactly one
    # page, so the Import::Row generated downstream can carry `source_page`.
    # A nil page (a multi-page batch) leaves the rows untouched.
    def tag_page(rows, page)
      return rows if page.nil?

      rows.map { |row| row.merge("source_page" => page) }
    end

    # Keeps the FIRST value reported for each field: the opening pages carry the
    # statement's identity, and a later batch (a continuation page, a summary
    # table) fills only what no earlier batch supplied.
    def merge_understanding(current, part)
      return part if current.nil?

      first = current.to_verdict
      incoming = part.to_verdict
      incoming.each { |key, value| first[key] = value if first[key].blank? && value.present? }
      DocumentUnderstanding.new(first)
    end
end
