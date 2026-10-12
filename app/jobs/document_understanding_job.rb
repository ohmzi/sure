# frozen_string_literal: true

# The native read: one idempotent job per document.
#
# paperless did this in two halves — Upload/TaskPoll/CaptureContent for the text,
# StatementOcrJob or ReceiptImport::UnderstandJob for the meaning. Both halves
# are one job now, because both halves need the same thing: the pages.
class DocumentUnderstandingJob < ApplicationJob
  queue_as :heavy

  # Pages per provider call. A statement page image is roughly 100-200 KB of
  # base64, so the batch is bounded by the request payload limit and the model's
  # context, whichever bites first.
  #
  # PLACEHOLDER, NOT A MEASUREMENT. The brief's Step 5 benchmarks this against a
  # real multi-page statement through a configured provider; that provider is not
  # configured in this environment, so no reading has been taken and none is
  # invented here. 4 is the plan's starting value and stays until the milestone's
  # live acceptance run (Task 13/14) raises it on real payload sizes and token
  # usage, at which point the measured number replaces this comment.
  PAGE_BATCH = 4

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

  # An OCR failure is transient far more often than it is terminal — the sidecar
  # is restarting, the GPU is busy, the weights are still loading. Retry with
  # backoff; only a service that ANSWERED and said "unreadable" lands terminally.
  #
  # The block runs once the retries are SPENT and the sidecar is still
  # unreachable, and lands the row terminally with a message. Without it the row
  # would rest at `processing` forever — invisible, and never re-driven (no sweep
  # touches a native row: DocumentLink.capture_pending_content keys on a
  # paperless_document_id the native path never sets). That silent wedge is the
  # predecessor's failure mode this milestone exists to remove.
  retry_on Ocr::Error, wait: :polynomially_longer, attempts: 8 do |job, error|
    DocumentLink.find_by(id: job.arguments.first)&.fail!(
      message: "OCR service unreachable after 8 attempts: #{error.message}"
    )
  end
  discard_on ActiveRecord::RecordNotFound

  UNREADABLE_MESSAGE = "the OCR engine found no text in this document".freeze
  NO_PROVIDER_MESSAGE = "no AI provider is configured".freeze

  # The deterministic cross-checks. Pure, so the review screen can call them and
  # so they are testable without a provider or a sidecar.
  def self.validate(understanding, ocr_text:)
    ai_total = understanding.total
    ocr_total = OcrTotal.call(ocr_text)

    line_items = understanding.line_items.map { |i| BigDecimal(i["amount"].to_s.delete(",")) rescue nil }
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
    # the case this milestone exists for. A provider failure is still a hold, not
    # a raise: the row stays retryable and visible rather than wedging the job.
    understanding =
      begin
        understand_in_batches(provider, result, link)
      rescue Provider::Error => e
        return link.hold!(message: e.message)
      end

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
                   classified_by: classification.classified_by)
    # Route while the link is still `processing` — settle! flips it to
    # `unlinked` immediately after, and link_to_entry! only accepts the
    # LINKABLE statuses (the routed draft is linked at PUBLISH, not here).
    route(link, understanding, classification)
    link.settle!
    link.broadcast_row_update!
  rescue Ocr::Error
    # Transient: let retry_on do its work. The row stays `processing`.
    raise
  rescue => e
    # Anything else is ours: record it on the link so the archive can show it,
    # and leave the row retryable rather than wedged.
    DocumentLink.find_by(id: document_link_id)&.hold!(message: "read failed: #{e.class}: #{e.message}")
    raise
  end

  private
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

    # The money-adjacent seam: a receipt or a bill becomes a reviewable draft,
    # filled from the same three-method contract `apply_extraction!` has always
    # consumed. Nothing here writes money — the reviewed publish does that.
    # find_or_create (never create) because a retry, a reaper re-enqueue or a
    # reprocess must adopt the draft it already made, not mint a second set of
    # rows.
    def route(link, understanding, classification)
      case classification.document_class
      when "receipt", "bill"
        draft = ReceiptImport.find_or_create_from_document_link!(document_link: link)
        draft.apply_extraction!(ReceiptImport::Understanding.new(understanding))
      when "statement"
        route_statement(link, understanding)
      else
        # "other": archived and deliberately not read for line items — the right
        # answer for a warranty or a lease. Nothing to route.
        nil
      end
    end

    # The statement seam: the document's own vault row plus a PdfImport holding
    # the statement's rows, in the state the review screen already knows how to
    # show. Nothing here writes money — the reviewed publish does that. Note that
    # the statement arrives with NO account: resolving one from the hints is
    # Task 10's job, so today an imported statement sits unmatched until the user
    # picks its account at the review step.
    def route_statement(link, understanding)
      statement = statement_for(link, understanding)
      import = PdfImport.find_or_create_from_statement!(statement: statement)

      import.update!(
        account_statement: statement,
        document_type: "bank_statement",
        ai_summary: I18n.t("imports.statement_ocr.summary", bank: understanding.institution_name.to_s,
                           version: understanding.period_start ? "period" : "unknown"),
        extracted_data: { "transactions" => understanding.transactions.map do |row|
          { "date" => row["date"].to_s, "amount" => row["amount"].to_s,
            "name" => row["name"].to_s, "notes" => row["notes"].to_s, "category" => "" }
        end }
      )
      import.generate_rows_from_extracted_data
      import.sync_mappings
      statement.update!(extraction_state: :extracted)
      import.update!(status: import.rows_count.positive? ? :pending : :complete)
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
        account_last4_hint: understanding.account_last4,
        # `currency`, not `statement_currency`: the latter is a reader on the
        # model (currency || account's || family's), not a column.
        currency: understanding.currency,
        period_start_on: understanding.period_start,
        period_end_on: understanding.period_end
      )
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

      result.pages.each_slice(PAGE_BATCH) do |pages|
        response = provider.understand_document(pages: pages.filter_map(&:image),
                                                ocr_text: pages.map(&:text).join("\n\n"),
                                                family: link.family)
        raise Provider::Error, "AI provider failed: #{response.error&.message}" unless response.success?

        part = response.data
        merged = merge_understanding(merged, part)
        transactions.concat(part.transactions)
      end

      merged.with_transactions(transactions)
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
