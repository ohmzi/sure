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

  # The bounded retry ladder for a transient OCR failure. One constant drives
  # both the policy (`attempts:`) and the terminal copy, so "after N attempts"
  # cannot drift from how many attempts are actually configured. A provider
  # failure no longer retries the same provider: the reader ladder moves on to
  # the next reader instead (spec §2).
  RETRY_ATTEMPTS = 3

  # A local read past its whole-document budget (Setting.local_llm_document_budget):
  # the ladder abandons it for the next reader so the GPU is never held unbounded.
  BudgetExceeded = Class.new(StandardError)
  # The read needs a model and this pass has none: the statement reader alone
  # could not finish the document.
  NoReaderAvailable = Class.new(StandardError)
  # A model's output the read could not use (a bug-shaped error inside the model
  # read): that reader failed, and the ladder moves on rather than asking it again.
  ModelReadFailed = Class.new(StandardError)

  # The ladder's result: the read that routes (nil when none produced one), the
  # reader that made it (nil when the statement's own text was enough), and one
  # entry per reader tried.
  LadderOutcome = Data.define(:read, :reader, :attempts, :corroborated) do
    def initialize(corroborated: false, **fields) = super(corroborated: corroborated, **fields)
  end

  # W8-D: one read's outcome. `understanding` is what routes; `statement_read` is
  # the reader's verdict (nil for a non-statement, which has no statement route
  # to guard); `model_understanding` is the MODEL's own read for the extraction's
  # `raw_response` (R-W8B17) — which on the identity-only path is the narrow
  # identity read, not a row table.
  DocumentRead = Data.define(:understanding, :statement_read, :model_understanding, :identity_source,
                             :row_orientation) do
    def initialize(identity_source: nil, row_orientation: nil, **fields)
      super(identity_source: identity_source, row_orientation: row_orientation, **fields)
    end
  end

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

  discard_on ActiveRecord::RecordNotFound

  # The user-facing wording for a read that produced nothing usable. Since
  # Ruling R14 a 422 from the sidecar means the service could not RENDER the
  # page (a corrupt file, a degenerate page) — not that the engine found no
  # text — so the message must say "could not be read", not "found no text".
  # The same sentence also covers the empty-200 read (no `pages` at all), where
  # there is no page to name; "document" is therefore the word that is right for
  # both paths. The `(code)` suffix the caller appends stays the diagnostic.
  UNREADABLE_MESSAGE = "This document could not be read".freeze

  # Wave 8, R-W8B19 as narrowed by W8-E: the verdicts from the statement reader
  # that HOLD — the read CONTRADICTS the statement (`:drift`), or it found no rows
  # where the statement states money (`:empty_but_expected`) — and ONLY when the
  # read came from the TEXT LAYER. A scanned statement (geometry/vision) whose
  # layout cannot be verified falls back to today's model path rather than
  # refusing the import: the exact, non-OCR text layer is the only source whose
  # contradiction is trustworthy enough to strand a document.
  STATEMENT_HOLD_VERDICTS = %i[drift empty_but_expected].freeze

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
    # The statement-rows observations. A statement whose rows arrived under
    # `line_items` (the model's field choice varies run to run) still yields rows
    # — `transactions` adopts them — but the fallback is recorded so it is
    # visible, never silent. Its rows carry no date, and none is invented, so the
    # date check surfaces that too (nil when there are no statement rows at all:
    # a receipt, or a statement the read found empty).
    statement_rows = understanding.transactions
    {
      "totals_agree" => (ai_total.present? && ocr_total.present? ? ai_total == ocr_total : nil),
      "ai_total" => ai_total&.to_s("F"),
      "ocr_total" => ocr_total&.to_s("F"),
      "line_items_sum" => sum_ok,
      "last4_in_ocr" => last4.empty? ? nil : last4.any? { |digits| ocr_text.to_s.include?(digits) },
      "date_parses" => understanding.date.present?,
      "statement_rows_from_line_items" => understanding.statement_rows_from_line_items?,
      "statement_rows_have_dates" => statement_rows.empty? ? nil : statement_rows.all? { |row| row["date"].present? }
    }
  end

  def perform(document_link_id, reader_mode = "auto")
    link = DocumentLink.find(document_link_id)

    # Idempotent: a re-delivery, or the reaper re-enqueueing, must be a no-op
    # once the read settled. `processing` is allowed so a crashed attempt resumes.
    return unless link.status.in?(%w[queued processing])

    link.mark_processing!

    unless Ocr.configured?
      return link.hold_for!(DocumentHold.named("ocr_not_configured", message: "no OCR service is configured"))
    end

    result = ocr_result(link)
    return land_unreadable(link, result.failure_code) if result.failure?
    # A genuine empty read (Task 3's client reads a body with no `pages` key as
    # a non-failure, empty result) is "nothing was understood": no text AND no
    # page images to send. Hold it for the user rather than settle a text-less
    # read. When the OCR found no text but DID render pages, those images are
    # exactly what the vision model is for — a text-less photo is the canonical
    # case, so forward them (Ruling R14).
    return land_unreadable(link, :no_text) if result.text.blank? && result.page_images.empty?

    link.record_content!(result.text, refresh: true)

    # Wave 8 (the statement row reader), W8-D: the model read is DEFERRED behind
    # the statement reader, which reads a statement's rows DETERMINISTICALLY
    # where it can and PROVES them against the printed totals; the model is
    # asked only for what the page cannot supply. The reader ladder (spec §2)
    # decides WHICH model: the selected provider, then the cloud readers.
    outcome = read_with_ladder(link, result, reader_mode)
    if outcome.read.nil?
      return link.hold_for!(DocumentHold.for_attempts(outcome.attempts), **failed_read_details(result, outcome.attempts))
    end

    read = outcome.read
    understanding = read.understanding
    statement_read = read.statement_read
    model_understanding = read.model_understanding

    validations = self.class.validate(understanding, ocr_text: result.text)
    validations = validations.merge(statement_read_validations(statement_read)) if statement_read
    validations["identity_source"] = read.identity_source if read.identity_source
    validations["statement_rows_orientation"] = read.row_orientation if read.row_orientation
    validations["read_attempts"] = outcome.attempts
    validations["statement_rows_corroborated"] = true if outcome.corroborated
    classification = classify(understanding, link, result, statement_read)

    DocumentExtraction.record!(
      document_link: link,
      provider: outcome.reader ? outcome.reader.provider.provider_name : STATEMENT_READER,
      model: outcome.reader&.provider&.llm_model,
      ocr_engine: result.engine,
      page_count: result.pages.size,
      ocr_text: result.text.first(DocumentLink::EXTRACTED_TEXT_LIMIT),
      raw_response: model_understanding.to_verdict,
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
    route(link, understanding, classification, ocr_text: result.text, statement_read: statement_read)
    link.settle!
    # A read that added up will not be retried; one that went to review may be.
    DocumentLink::OcrCache.delete(link) if standing(read) == :proven
    link.broadcast_row_update!
  rescue Ocr::Error => e
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
    held = DocumentLink.find_by(id: document_link_id)
    begin
      held&.hold_for!(DocumentHold.named("read_error", message: "This document could not be read. Retry it from the archive."))
    rescue StandardError
      held&.hold!(message: "This document could not be read. Retry it from the archive.")
    end
  end

  private
    # The transient-retry reason the user reads, chosen by error code — never
    # the raw exception text, which belongs in the log. Both the OCR codes the
    # client can raise and a provider failure get their own sentence.
    def retry_message(error)
      case error.code
      when :not_configured then "The OCR service is not configured; a retry is scheduled."
      when :unreachable then "The OCR service is unreachable; a retry is scheduled."
      when :server_error then "The OCR service reported an error; a retry is scheduled."
      when :bad_response then "The OCR service returned an unexpected response; a retry is scheduled."
      else "This document could not be read; a retry is scheduled."
      end
    end

    # The provider name a read made without any model records.
    STATEMENT_READER = "statement reader"

    # Spec §2/§3: a no-model pass first — a proven statement with a complete
    # printed identity is finished without any reader — then each reader in
    # turn. An automatic read skips a local reader whose GPU is busy (a manual
    # "Retry with local model" waits instead); a local reader is bounded by its
    # document budget and unloaded when it ran. A statement whose rows do not
    # add up moves on to the next reader; when none do, the fullest read routes
    # for review.
    def read_with_ladder(link, result, reader_mode)
      begin
        read = read_document(link, nil, result)
        if standing(read) == :proven
          return LadderOutcome.new(read: read, reader: nil, attempts: [ attempt_entry(nil, "read", 0) ])
        end
      rescue NoReaderAvailable
        # The page alone is not enough; the readers below are.
      end

      attempts = []
      best = nil
      unverified = []
      DocumentReaderLadder.for(mode: reader_mode).each do |reader|
        # A provider that cannot read documents (Anthropic today) is no rung.
        next unless reader.provider.respond_to?(:supports_document_understanding?) &&
                    reader.provider.supports_document_understanding?

        started = monotonic_now
        @provider_called = false
        @deadline = reader.local? ? started + Setting.local_llm_document_budget.to_i : nil
        # An automatic read never queues behind another model on the GPU; a
        # retry the owner chose waits its turn, within the document budget.
        if reader.local? && !(reader_mode == "auto" ? !reader.guard&.busy? : wait_for_gpu(reader.guard))
          attempts << attempt_entry(reader, "skipped_busy", monotonic_now - started)
          next
        end
        # A model already resident belongs to someone else's read: leave it.
        was_resident = reader.local? && reader.guard&.loaded?
        begin
          read = read_document(link, reader.provider, result)
          case standing(read)
          when :proven
            attempts << attempt_entry(reader, "read", monotonic_now - started)
            return LadderOutcome.new(read: read, reader: reader, attempts: attempts)
          when :unverified
            # Nothing on the page to check it against: keep it, and let the
            # next (stronger) reader have a turn too.
            attempts << attempt_entry(reader, "unverified", monotonic_now - started)
            unverified << [ read, reader ]
          else
            attempts << attempt_entry(reader, "did_not_add_up", monotonic_now - started,
                                      detail: read.statement_read&.verdict.to_s)
            best = [ read, reader ] if best.nil? || row_count(read) > row_count(best.first)
          end
        rescue BudgetExceeded
          attempts << attempt_entry(reader, "timed_out", monotonic_now - started)
        rescue Provider::Error => e
          Rails.logger.warn("DocumentUnderstandingJob reader #{reader.label} failed for document_link #{link.id}: #{e.message}")
          outcome = e.message.match?(/timeout|timed out|execution expired/i) ? "timed_out" : "failed"
          attempts << attempt_entry(reader, outcome, monotonic_now - started, detail: e.message.to_s.first(200))
        rescue ModelReadFailed, NoMethodError, TypeError, JSON::ParserError => e
          # Spec §2: output the read cannot use moves on to the next reader.
          Rails.logger.warn("DocumentUnderstandingJob reader #{reader.label} gave unusable output for document_link #{link.id}: #{e.message}")
          attempts << attempt_entry(reader, "failed", monotonic_now - started)
        ensure
          reader.guard&.unload! if reader.local? && @provider_called && !was_resident
          @deadline = nil
        end
      end

      return choose_unverified(unverified, attempts) if unverified.any?

      LadderOutcome.new(read: best&.first, reader: best&.last, attempts: attempts)
    end

    # Among reads nothing could verify: two readers that agree row for row
    # corroborate each other; otherwise the last reader's (the ladder runs from
    # the local model to the stronger cloud readers). Either way it goes to
    # review — unverified is never reconciled, never auto-posted.
    def choose_unverified(unverified, attempts)
      fingerprints = unverified.map { |read, _| row_fingerprint(read) }
      agreeing = fingerprints.each_index.find { |i| fingerprints.count(fingerprints[i]) > 1 && fingerprints[i].any? }
      read, reader = agreeing ? unverified[agreeing] : unverified.last
      LadderOutcome.new(read: read, reader: reader, attempts: attempts, corroborated: !agreeing.nil?)
    end

    def row_fingerprint(read)
      read.understanding.transactions.map { |row| [ row["date"].to_s, BigDecimal(row["amount"].to_s.delete("$,")).round(2) ] }.tally
    rescue ArgumentError
      {}
    end

    GPU_WAIT_POLL = 10

    # True once the GPU is free; false when it stayed busy past the deadline.
    def wait_for_gpu(guard)
      return true if guard.nil?

      loop do
        return true unless guard.busy?
        return false if @deadline && monotonic_now >= @deadline

        sleep(GPU_WAIT_POLL)
      end
    end

    # Where a read stands: :proven (a non-statement, or a statement reconciled
    # to its printed totals), :short (checked against the page and it did not
    # add up), or :unverified (a statement with nothing on the page the reader
    # could check it against — never accepted as if it were proven).
    def standing(read)
      statement_read = read.statement_read
      return :proven if statement_read.nil? || statement_read.reconciled?
      return :short if statement_read.verdict.in?(STATEMENT_HOLD_VERDICTS)

      :unverified
    end

    def row_count(read) = read.understanding.transactions.size

    def attempt_entry(reader, outcome, seconds, detail: nil)
      { "reader" => reader&.label || STATEMENT_READER, "kind" => reader&.kind&.to_s || "text",
        "outcome" => outcome, "seconds" => seconds.round(1), "detail" => detail.presence }.compact
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Every reader failed (or there was none): the attempts ride on the failed
    # read record the hold is kept on, so the document can say what was tried.
    def failed_read_details(result, attempts)
      { ocr_engine: result.engine, page_count: result.pages.size,
        ocr_text: result.text.first(DocumentLink::EXTRACTED_TEXT_LIMIT),
        validations: { "read_attempts" => attempts } }
    end

    # The OCR a read works from: the cached result of an earlier read of this
    # document when there is one, so a retry never re-runs OCR on the GPU.
    def ocr_result(link)
      cached = DocumentLink::OcrCache.read(link)
      return cached if cached

      fresh = read(link)
      DocumentLink::OcrCache.write(link, fresh) unless fresh.failure? || fresh.pages.empty?
      fresh
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
      link.hold_for!(DocumentHold.named("ocr_unreadable", message: "#{UNREADABLE_MESSAGE} (#{code})"))
    end

    # The document's class, decided by the model's identity read UNLESS the
    # reader PROVED a statement. Must-fix 2: the identity read is issued BY the
    # branch that trusts the read, so it cannot gate it — and
    # DocumentClassifier falls to `other` the moment that identity read says
    # nil/other. But the reader's gate is statement-specific arithmetic: it
    # requires the printed totals (`Total credits`, `Total charges`, purchases,
    # opening and closing balance) that a receipt or bill never prints, so a
    # reconciled DETERMINISTIC read is itself proof the document is a statement.
    # Such a document routes as a statement (through the existing statement path,
    # including its permission gate) regardless of what the model called it.
    # `classified_by: "reader"` records that the class came from the proof (the
    # verdict and source already ride the extraction's `statement_read`
    # diagnostic). A document the reader did NOT reconcile is left entirely
    # untouched — that is the fence.
    def classify(understanding, link, result, statement_read)
      classification = DocumentClassifier.call(
        ai_verdict: understanding, filename: link.original_filename,
        content_type: link.content_type, ocr_text: result.text
      )
      return classification unless reader_proved_statement?(statement_read)

      DocumentClassifier::Result.new(
        document_class: "statement", confidence: classification.confidence,
        corroborated: true, classified_by: "reader"
      )
    end

    # The reader PROVED a statement: a DETERMINISTIC rung (never the vision rung,
    # whose rows are the model's) reconciled to the cent. The same predicate the
    # trusted branch and `adopt_reader_rows` use.
    def reader_proved_statement?(read)
      read&.reconciled? && read.source != :vision
    end

    # W8-D: read the document, asking the model for a statement's ROW TABLE only
    # when the deterministic read cannot supply it.
    #
    # The reader's ladder (text layer -> geometry -> vision) decides the SHAPE of
    # the model call: it invokes `vision` — the full read, rows wanted — only when
    # no deterministic rung PROVES the rows. A trusted text-layer/geometry read
    # instead takes a narrow IDENTITY-ONLY call, so the model never enumerates a
    # table whose rows the app already holds. A non-statement, a scan, and a
    # statement whose deterministic read did not reconcile all reach `vision` and
    # get today's full read, byte-for-byte.
    #
    # Returns a DocumentRead. The read is ALWAYS present for a statement — a
    # synthetic `:unavailable` read stands in on an unexpected reader failure — so
    # the statement route can never skip its fail-closed guard by not mentioning
    # one (R-W8B18). It is nil only for a non-statement, which has no statement
    # route to guard.
    def read_document(link, provider, result)
      model_understanding = nil
      read =
        begin
          StatementRead.call(link: link, ocr_result: result,
                             vision: (vision_read(provider, result, link) { |read| model_understanding = read } if provider))
        rescue Provider::Error, BudgetExceeded, NoReaderAvailable, ModelReadFailed
          # A provider failure is transient (the retry_on ladder), never a reader
          # failure: let it propagate exactly as it did when the read ran before
          # the reader.
          raise
        rescue StandardError => e
          # A reader failure is never a read failure: log it and keep today's
          # path — but the statement route still carries a read, so its guard is
          # structural.
          Rails.logger.warn("StatementRead failed for document_link #{link.id}: #{e.class}: #{e.message}")
          unavailable_read
        end

      if read.reconciled? && read.source != :vision
        # A DETERMINISTIC rung supplied the rows and they reconcile. When the
        # page also prints a complete identity, nothing is left for a model to
        # read (spec §1): no call at all, so no GPU and no cloud egress.
        if read.identity&.complete?
          printed = DocumentUnderstanding.new(printed_identity_verdict(read))
          return DocumentRead.new(understanding: adopt_reader_rows(printed, read), statement_read: read,
                                  model_understanding: printed, identity_source: "text_layer")
        end

        # Otherwise the model is asked for IDENTITY ONLY. `adopt_reader_rows`
        # (R-W8B12) replaces any rows the model volunteered with the reader's
        # proven ones and clears the line_items fallback, so nothing
        # mixed-provenance routes.
        identity = understand_in_batches(provider, result, link, rows_expected: false)
        DocumentRead.new(understanding: adopt_reader_rows(overlay_printed_identity(identity, read), read),
                         statement_read: read, model_understanding: identity,
                         identity_source: read.identity ? "text_layer+model" : "model")
      else
        # The ladder already made the full read (rows wanted). If a reader failure
        # struck before the vision call there is no understanding yet, so fall
        # back to the full read — today's path either way.
        understanding = model_understanding || understand_in_batches(provider, result, link)
        if understanding.document_class == "statement"
          oriented = StatementRead::SignOrientation.call(understanding.transactions, read.stated_totals)
          routed = overlay_printed_identity(understanding.with_transactions(oriented.rows), read)
          DocumentRead.new(understanding: adopt_reader_rows(routed, read),
                           statement_read: read, model_understanding: understanding,
                           identity_source: read.identity ? "text_layer+model" : "model",
                           row_orientation: (oriented.orientation.to_s unless read.reconciled? && read.source != :vision))
        else
          DocumentRead.new(understanding: understanding, statement_read: nil,
                           model_understanding: understanding)
        end
      end
    end

    # The statement reader's vision rung: the model's full read. A failure that
    # is not the provider's (an output the read could not use) is re-raised as
    # ModelReadFailed so the statement reader's own rescue cannot swallow it and
    # send the same model a second, identical request.
    def vision_read(provider, result, link)
      lambda do
        yield understand_in_batches(provider, result, link)
      rescue Provider::Error, BudgetExceeded, NoReaderAvailable
        raise
      rescue StandardError => e
        raise ModelReadFailed, "#{e.class}: #{e.message}"
      end
    end

    # R-W8B12: when a DETERMINISTIC rung supplied the rows (text layer or
    # geometry — the vision rung's rows ARE the model's, so they are left alone),
    # the routed rows are the reader's, not the model's. Replace the model's rows
    # and CLEAR the line_items-fallback flag, or `validate` keeps a mixed-
    # provenance green claiming the model supplied rows the reader supplied. The
    # reader's rows are ISO-dated and period-anchored already, so
    # `normalise_statement_dates` must NOT touch them — a second re-anchor is a
    # subtle way to move a date, and they never reach it because the replacement
    # happens after `understand_in_batches`.
    #
    # Must-fix 2: the reader also DECIDES the class for routing. `transactions`
    # is gated on the document's class, so an identity read that called the
    # document `other` would gate the reader's proven rows out (route_statement
    # would write an empty import); the proof sets the class to `statement` so
    # the routed verdict is a statement. The model's own read is preserved
    # unchanged on `model_understanding` (the extraction's `raw_response`).
    def adopt_reader_rows(understanding, read)
      return understanding unless read.reconciled? && read.source != :vision

      proof = DocumentUnderstanding.new(understanding.to_verdict.merge("document_class" => "statement"))
      proof.with_transactions(read.rows).with_statement_rows_fallback(false)
    end

    # The statement's identity as the page prints it, plus the two figures a
    # reader of the verdict expects: the new balance as the statement's total
    # and its closing date as its date.
    def printed_identity_verdict(read)
      fields = read.identity.to_verdict_fields
      new_balance = read.stated_totals["new_balance"]
      fields["total"] = new_balance.to_s("F") if new_balance
      fields["date"] = read.identity.period_end&.iso8601
      fields.compact
    end

    # Spec §1: a field the page prints always wins over the model's read of it;
    # the model only fills what the page does not print.
    def overlay_printed_identity(understanding, read)
      return understanding unless read&.identity

      DocumentUnderstanding.new(understanding.to_verdict.merge(read.identity.to_verdict_fields.except("document_class")))
    end

    # A statement route MUST carry a read (R-W8B18). This stands in on an
    # unexpected reader failure: `:unavailable` falls back to today's path
    # (R-W8B19), exactly as if the reader had been unavailable, and the guard is
    # still evaluated rather than skipped.
    def unavailable_read
      StatementRead::Result.new(
        rows: [], stated_totals: {}, deltas: {}, checks: {}, reconciled: false,
        missing_date_rows: [], rejected_lines: [], source: nil, verdict: :unavailable,
        figures: {}, rounding_delta: BigDecimal(0)
      )
    end

    # The read's full detail, merged onto the extraction's validations (§4,
    # R-W8B10/R-W8B13/R-W8B16). A read that GOVERNS the routing (see
    # `statement_read_governs?`) surfaces the four panel keys; one that merely
    # falls back records only WHY, so a normal scan or photo that imports fine is
    # never shown a scary red (R-W8B14b). The per-check detail is nested under
    # `statement_read`, an unmapped key the panel omits — a held document the
    # owner cannot diagnose is the failure this exists to prevent.
    def statement_read_validations(read)
      merged = { "statement_read" => statement_read_detail(read) }
      # The owner's decision (2026-10-16): a read whose rows were checked against
      # the statement's printed money totals and did NOT match goes to review
      # marked as not adding up. A row with no date alone (no money check
      # failed) still never paints the check red (R-W8B14b).
      merged["statement_totals_reconcile"] = false if !statement_read_governs?(read) && money_drift?(read)
      return merged unless statement_read_governs?(read)

      merged.merge(
        # R-W8B10: each stores the property its LABEL claims, so each can fail.
        "statement_totals_reconcile" => read.reconciled?,
        "statement_row_count" => read.row_count,
        # A read that produced NO rows asserts nothing about their dates, so the
        # key is nil (not `true`) — `empty?` is vacuously true on an empty set,
        # and a green "no statement row is missing its date" beside a red row
        # count is exactly the vacuous green R-W8B10 forbids. Matches the wave-6
        # sibling (`statement_rows_have_dates`, whose `statement_rows.empty? ?
        # nil : ...` nils the identical case).
        "statement_rows_missing_dates" => read.rows? ? read.missing_date_rows.empty? : nil,
        # R-W8B13: provenance, rendered with a source-naming label, never red.
        "statement_rows_source" => read.source&.to_s
      )
    end

    def money_drift?(read)
      read.checks.any? do |name, state|
        state == StatementRead::Reconciliation::DRIFT &&
          (StatementRead::Reconciliation::STRONG.include?(name) || name.start_with?("card_"))
      end
    end

    # Does the read GOVERN the routing — decide it rather than merely advise it?
    # True when it supplies the routed rows (`:trusted`) or HOLDS them
    # (`statement_holds?`). False on every fall-back verdict: one that could not
    # engage, and — the W8-E scoping — a `:drift` from a SCAN (geometry or
    # vision). Such a drift is either the model's OWN rows failing a gate that is
    # not the statement's own arithmetic (the usual dateless `line_items`
    # fallback) or an untrusted OCR read of a scan; stranding a document that
    # imports fine today is exactly what the named fence in
    # document_understanding_job_test.rb forbids. Its detail is recorded only when
    # this read is the one the ladder keeps as the fallback: when a usable text
    # layer ALSO failed the gate, the ladder prefers the text-layer Result and the
    # scan drift's own detail is dropped, not recorded.
    def statement_read_governs?(read)
      read.reconciled? || statement_holds?(read)
    end

    # R-W8B19 as narrowed by W8-E: the verdicts that HOLD — a read CONTRADICTS
    # the statement (`:drift`) or finds no rows where it states money
    # (`:empty_but_expected`) — from the TEXT LAYER only. The old `source !=
    # :vision` exclusion is subsumed: a geometry-rung drift is no longer held (the
    # owner's answer — a scan whose layout cannot be verified behaves as today),
    # and the vision rung never carried `:text_layer` either. Neither held verdict
    # ever carries a nil source, so only the text layer can hold.
    def statement_holds?(read)
      read.verdict.in?(STATEMENT_HOLD_VERDICTS) && read.source == :text_layer
    end

    # Every check, both its figures, the statement's own stated totals and the
    # lines the reader could not place — the evidence a hold must carry.
    def statement_read_detail(read)
      {
        "verdict" => read.verdict.to_s,
        "source" => read.source&.to_s,
        "checks" => read.checks,
        "figures" => read.figures.transform_values { |figure| figure.transform_values(&:to_s) },
        "deltas" => read.deltas.transform_values(&:to_s),
        "stated_totals" => read.stated_totals.transform_values do |value|
          value.is_a?(Hash) ? value.transform_values(&:to_s) : value&.to_s
        end,
        "rejected_lines" => read.rejected_lines,
        "missing_date_rows" => read.missing_date_rows,
        "rounding_delta" => read.rounding_delta.to_s
      }
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
    def route(link, understanding, classification, ocr_text:, statement_read:)
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
        # R-W8B18: the read is REQUIRED on the statement path (its keyword has no
        # default), so the fail-closed guard cannot be skipped by omission.
        route_statement(link, understanding, statement_read: statement_read)
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
    def route_statement(link, understanding, statement_read:)
      # The intake no longer asks the user what a document is, so this guard has
      # nothing to test at staging time — it belongs where the vault row would be
      # created. Refusing here leaves the document read, archived and visible with
      # a reason, which is strictly better than the old tile's "not authorized"
      # redirect that discarded the upload outright.
      unless AccountStatement.statement_manager?(link.created_by)
        return link.hold_for!(DocumentHold.named("statement_permission", message: I18n.t("documents.held.statement_permission")),
                              extraction: link.extraction)
      end

      # R-W8B19 + R-W8B18, as narrowed by W8-E: the reader's verdict decides. A
      # TEXT-LAYER read that CONTRADICTS the statement (`:drift`) or that found
      # no rows where the statement states money (`:empty_but_expected`) is HELD
      # with the reader's own sentence and NOTHING is routed — the per-check
      # detail is already on the extraction. A `:drift` from a scan (geometry or
      # vision), and every verdict that could not engage (`:unreconcilable`/
      # `:period_unreadable`/`:unavailable`), fall back to today's path. The
      # argument is REQUIRED, so no statement route can skip this guard by not
      # mentioning it.
      if statement_holds?(statement_read)
        return link.hold_for!(DocumentHold.named("statement_drift", message: statement_read.hold_message),
                              extraction: link.extraction)
      end

      statement = statement_for(link, understanding)
      # W8-I: the statement's OWN printed balances, from the reader's parse.
      record_stated_balances(statement, statement_read)
      record_card_last4s(statement, statement_read)
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

    # W8-I: write the statement's OWN printed balances onto its record. The
    # reader's `stated_totals` are the figures the statement PRINTS, parsed
    # independently of whether the rows reconciled — so a read that fell back
    # (`:unreconcilable` / `:period_unreadable` / `:unavailable`, or a scan's
    # `:drift`) may still carry a genuine opening or closing, and this writes it
    # without consulting the verdict. Equally, a figure the reader did NOT parse
    # leaves its column as it is: an absent parse is not a figure, and neither a
    # guessed sum nor the ledger's own balance may stand in for one, because the
    # statement page's reconciliation (`AccountStatement#reconciliation_checks`)
    # reads exactly these two columns and must compare the PRINTED figure, never
    # one the app supplied. Only the parsed keys are written, so a re-read updates
    # the same two columns and nothing is appended or duplicated.
    #
    # The hold is evaluated before `statement_for`, so a held read reaches no
    # statement and this method is never called for one — not special-cased here.
    def record_stated_balances(statement, statement_read)
      totals = statement_read&.stated_totals || {}
      parsed = {
        opening_balance: totals["opening"],
        closing_balance: totals["new_balance"]
      }.compact
      return if parsed.empty?

      statement.update!(parsed)
    end

    # Every card the statement lists (a supplementary card prints its own
    # block), kept for account matching: Account#known_card_last4s reads them.
    def record_card_last4s(statement, statement_read)
      cards = statement_read&.identity&.card_last4s
      return if cards.blank?

      statement.update!(sanitized_parser_output: statement.sanitized_parser_output.to_h.merge("card_last4s" => cards))
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
    #
    # `rows_expected: false` (W8-D) is the identity-only read: the request
    # withdraws the statement's row table so the model supplies identity alone.
    # The flag is passed to the provider ONLY when false, so the full read's
    # request is byte-for-byte today's.
    def understand_in_batches(provider, result, link, rows_expected: true)
      raise NoReaderAvailable if provider.nil?

      merged = nil
      transactions = []
      line_items = []
      fell_back = false

      result.pages.each_slice(self.class.page_batch_size) do |pages|
        # The read's heartbeat (Task 11 fix round 1): a long multi-batch read
        # must keep its row fresh, or the reaper's staleness test would
        # re-enqueue it while it is still running — a second OCR run, a second
        # paid provider call, a second extraction.
        link.heartbeat!
        raise BudgetExceeded if @deadline && monotonic_now > @deadline

        @provider_called = true
        response = provider.understand_document(**document_request(pages, merged, link, rows_expected))
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
        #
        # The rows a batch carries sit in exactly ONE field, because one provider
        # call returns one object: whichever field the model chose. Pick that field
        # here, per batch, so a page the model filed under `line_items` is kept
        # even when another page used `transactions` — the document-level fallback
        # cannot see it (`transactions` non-empty masks it) and the loss would be
        # silent. A per-batch pick cannot double-count: one call, one field.
        #
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
        batch_rows = part.statement_row_candidates
        fell_back = true if part.transaction_rows.empty? && batch_rows.any?
        transactions.concat(tag_page(batch_rows, page))
        line_items.concat(tag_page(part.line_items, page))
      end

      # The gate is therefore the MERGED verdict's class — the first batch that
      # reported one, which is also exactly what DocumentClassifier judges and
      # what `transactions` itself gates on, so a read that will be routed as a
      # statement always carries every batch's rows. Line items go on every read;
      # they are the receipt/bill leg's payload and the statement's reader ignores
      # them. A statement's row dates are re-anchored to its own period before
      # they are stitched in, so a yearless "Sep 20" lands in the period's year
      # and not a year the model invented. The per-batch fallback is carried onto
      # the verdict so the read's marker fires even when the stitched
      # `transactions` is non-empty (some pages used `transactions`, others did
      # not) — otherwise the owner would see an all-green panel while rows are
      # gone.
      if merged.document_class == "statement"
        merged.with_transactions(normalise_statement_dates(transactions, merged))
              .with_line_items(line_items)
              .with_statement_rows_fallback(fell_back)
      else
        merged.with_line_items(line_items)
      end
    end

    # The provider request for one batch. `rows_expected: false` is added ONLY
    # for the identity-only read, so the full read keeps the exact call shape it
    # has always had (and every provider double keeps working unchanged).
    def document_request(pages, merged, link, rows_expected)
      request = { pages: pages.filter_map(&:image), ocr_text: batch_ocr_text(pages, merged),
                  family: link.family }
      request[:rows_expected] = false unless rows_expected
      request
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
