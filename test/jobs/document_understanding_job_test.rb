require "test_helper"

class DocumentUnderstandingJobTest < ActiveSupport::TestCase
  # The transient-OCR test asserts on the retry the job enqueues
  # (assert_enqueued_jobs), which lives in ActiveJob::TestHelper (the repo
  # convention — see test/models/document_link_test.rb).
  include ActiveJob::TestHelper

  # A provider double, so this job's tests never touch HTTP. Task 5's provider
  # has its own tests for the wire format.
  class FakeProvider
    attr_reader :provider_name, :llm_model

    def initialize(verdict, success: true)
      @provider_name = "openai"
      @llm_model = "deepseek-flash"
      data = success ? DocumentUnderstanding.new(verdict) : nil
      @response = Struct.new(:success?, :data, :error).new(success, data, (StandardError.new("boom") unless success))
    end

    def supports_document_understanding? = true
    def understand_document(pages:, ocr_text:, family: nil, model: "") = @response
  end

  # A provider double that answers each batch differently. FakeProvider returns
  # the SAME verdict for every call, so it can show accumulation but not that a
  # batch which disagrees with the document survives — the case review finding 4
  # is about. This one hands out one verdict per call; a call past the end of the
  # script re-uses the last verdict, since only the batches a test scripts are
  # interesting.
  class ScriptedProvider
    Response = Struct.new(:success?, :data, :error)

    attr_reader :provider_name, :llm_model

    def initialize(*verdicts)
      @verdicts = verdicts
      @calls = 0
    end

    def supports_document_understanding? = true

    def understand_document(pages:, ocr_text:, family: nil, model: "")
      verdict = @verdicts[[ @calls, @verdicts.size - 1 ].min]
      @calls += 1
      Response.new(true, DocumentUnderstanding.new(verdict), nil)
    end
  end

  RECEIPT = {
    "document_class" => "receipt", "total" => "12.34", "date" => "2026-10-01",
    "payee" => "Acme Store", "currency" => "USD", "card_last4" => "4242",
    "line_items" => [ { "description" => "Coffee", "amount" => "12.34" } ],
    "field_confidence" => { "total" => 0.98, "date" => 0.97 }
  }.freeze

  STATEMENT = {
    "document_class" => "statement", "institution_name" => "Chase", "account_last4" => "1234",
    "statement_period" => { "start" => "2026-09-01", "end" => "2026-09-30" },
    "currency" => "USD", "total" => nil, "date" => nil, "payee" => nil, "line_items" => [],
    "transactions" => [
      { "date" => "2026-09-03", "amount" => "-12.34", "name" => "Cafe", "notes" => "" },
      { "date" => "2026-09-05", "amount" => "-50.00", "name" => "Fuel", "notes" => "" }
    ],
    "field_confidence" => { "institution_name" => 0.95 }
  }.freeze

  setup do
    @family = families(:dylan_family)
    # The uploader is the statement permission's subject now that the vault row
    # is created here rather than by the wizard's statement tile (Task 2). A real
    # link always carries its uploader (DocumentLink.link_from_upload!), so the
    # default fixture names a statement manager and every statement test below
    # exercises the permitted path unless it says otherwise.
    @link = DocumentLink.create!(family: @family, created_by: users(:family_admin), source: "other", status: "queued",
                                 original_filename: "receipt.png", content_type: "image/png")
    @link.stage!(io: StringIO.new("PNG-#{SecureRandom.hex(4)}"), filename: "receipt.png",
                 content_type: "image/png")
    @link.update!(status: "queued")
  end

  def stub_provider(provider)
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
  end

  test "a readable receipt is snapshotted, classified and left unlinked" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.reload

    assert_equal "unlinked", @link.status
    assert_equal "receipt", @link.source
    assert_equal "ai", @link.classified_by
    assert_includes @link.extracted_text, "TOTAL 12.34"
    assert_equal 1, @link.page_count

    extraction = @link.extraction
    assert_equal "succeeded", extraction.status
    assert_equal "openai", extraction.provider
    assert_equal "deepseek-flash", extraction.model
    assert_includes extraction.ocr_text, "TOTAL 12.34"
    assert_equal "receipt", extraction.verdict["document_class"]
  end

  test "a re-delivery against a settled row is a no-op" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    provider = FakeProvider.new(RECEIPT)
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.reload
    assert_equal "unlinked", @link.status
    assert_equal 1, @link.document_extractions.count

    # The row already settled, so a re-delivery (or a reaper re-enqueue) must do
    # nothing: no second verdict, no second extraction, no second paid call.
    provider.expects(:understand_document).never
    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "unlinked", @link.reload.status
    assert_equal 1, @link.document_extractions.count
  end

  test "the page images and the OCR text both reach the provider" do
    seen = nil
    provider = FakeProvider.new(RECEIPT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: ""|
      seen = { pages: pages, ocr_text: ocr_text }
      @response
    end
    stub_ocr_success(pages: [ { page: 1, text: "TOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal [ "iVBORw0KGgo=" ], seen[:pages]
    assert_equal "TOTAL 12.34", seen[:ocr_text]
  end

  test "a text-less page with an image is forwarded to the vision model" do
    # Ruling R14: the vision model reads page images precisely when the OCR is
    # poor, so a photographed page with no recognised glyphs must reach it — not
    # be held as "unreadable". The empty OCR text makes the total uncheckable
    # (totals_agree nil), so this can never satisfy a later auto-post gate.
    seen = nil
    provider = FakeProvider.new(RECEIPT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: ""|
      seen = { pages: pages, ocr_text: ocr_text }
      @response
    end
    stub_ocr_success(pages: [ { page: 1, text: "", confidence: 0.0, image: "iVBORw0KGgo=" } ])
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.reload

    assert_equal "unlinked", @link.status
    assert_equal [ "iVBORw0KGgo=" ], seen[:pages]
    assert_equal "", seen[:ocr_text]
    assert_equal "succeeded", @link.extraction.status
    assert_nil @link.extraction.validations["totals_agree"],
               "no OCR text means the total is uncheckable, never agreed"
  end

  test "a document the OCR cannot read lands visibly and is never lost" do
    stub_request(:post, "#{Ocr.url}/ocr").to_return(status: 422, body: { error: "unreadable" }.to_json)
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.reload

    assert_equal "queued", @link.status
    assert_includes @link.failure_message, "could not be read"
    assert_nil @link.extraction
    assert_not_nil @link.stored_path, "the original bytes must survive an unreadable read"
  end

  test "an unreadable document never reaches a paid provider call" do
    # The hold paths above use a permissive provider stub, so a regression that
    # moved the provider call ABOVE the failure guard would pass them all. The
    # negative expectation is the actual pin.
    provider = FakeProvider.new(RECEIPT)
    stub_provider(provider)
    provider.expects(:understand_document).never
    stub_request(:post, "#{Ocr.url}/ocr").to_return(status: 422, body: { error: "unreadable" }.to_json)

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "queued", @link.reload.status
  end

  test "an empty 200 read lands as held-for-input, never a silent success" do
    # Sharp edge carried in from Task 3's review: a 200 with valid JSON but no
    # `pages` key is a non-failure, empty result on the client. It must land as
    # nothing-was-understood (held, with a message), never settle a row with no
    # text and never reach the paid provider.
    stub_request(:post, "#{Ocr.url}/ocr").to_return(status: 200, body: { engine: "paddleocr-3.0" }.to_json,
                                                     headers: { "Content-Type" => "application/json" })
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.reload

    assert_equal "queued", @link.status
    assert_includes @link.failure_message, "could not be read"
    assert_nil @link.extraction
    assert_not_nil @link.stored_path
  end

  test "an unreachable OCR service parks the row for the scheduled retry, never settles it" do
    stub_request(:post, "#{Ocr.url}/ocr").to_raise(Faraday::ConnectionFailed.new("refused"))
    stub_provider(FakeProvider.new(RECEIPT))

    # retry_on swallows the error and re-enqueues rather than letting it escape,
    # so the assertion is on the state it leaves behind, not on a raised class.
    # Fix round 2: the row is parked `queued` WITH a reason while the ladder
    # waits, so the sweep cannot race the scheduled retry into a second read.
    DocumentUnderstandingJob.perform_now(@link.id)
    @link.reload

    assert_equal "queued", @link.status
    assert_includes @link.failure_message, "retry"
    assert_enqueued_jobs 1, only: DocumentUnderstandingJob
    assert_nil @link.extraction, "a failed read must not record a verdict"
  end

  test "restarting the read after an OCR failure clears the backoff mark" do
    stub_request(:post, "#{Ocr.url}/ocr").to_raise(Faraday::ConnectionFailed.new("refused"))
    stub_provider(FakeProvider.new(RECEIPT))
    DocumentUnderstandingJob.perform_now(@link.id)
    assert_includes @link.reload.failure_message, "retry"

    # The scheduled retry runs the read again; mark_processing! clears the mark,
    # so a crash now is a plain stale `processing` row the sweep can revive.
    assert @link.mark_processing!
    assert_nil @link.reload.failure_message
  end

  test "a persistent OCR outage lands the row terminally once the retries are spent" do
    stub_request(:post, "#{Ocr.url}/ocr").to_raise(Faraday::ConnectionFailed.new("refused"))
    stub_provider(FakeProvider.new(RECEIPT))

    # Drive the REAL retry ladder instead of seeding ActiveJob's internal
    # `exception_executions` hash: perform_enqueued_jobs' block form performs the
    # retry chain (including the `wait:`-scheduled re-enqueues), so each transient
    # failure re-enqueues until the attempts are spent and the retry_on block
    # lands the row terminally — the state the per-attempt test above never
    # reaches. No ActiveJob-internal key is assumed, so a Rails change cannot
    # silently stop exercising this path.
    perform_enqueued_jobs(only: DocumentUnderstandingJob) do
      DocumentUnderstandingJob.perform_later(@link.id)
    end

    assert_equal "failed", @link.reload.status
    assert_includes @link.failure_message, "unreachable"
    assert_nil @link.extraction
  end

  test "a failed provider call parks the row for the retry ladder, never settling it" do
    stub_ocr_success(pages: [ { page: 1, text: "TOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT, success: false))

    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      DocumentUnderstandingJob.perform_now(@link.id)
    ensure
      Rails.logger = original_logger
    end
    @link.reload

    # Fix round 2: a provider failure is transient far more often than terminal,
    # and a held row is excluded from the sweep (finding 2) — so it joins the
    # same bounded ladder as an OCR blip (parked queued + reason, retry
    # scheduled) rather than waiting for a human. The reason the user reads is a
    # sentence (cleanup wave, item 3); the provider's raw message stays in the log.
    assert_equal "queued", @link.status
    assert_includes @link.failure_message, "retry is scheduled"
    assert_no_match(/AI provider failed/, @link.failure_message,
                    "the provider's raw message must not reach the user")
    assert_includes log.string, "AI provider failed", "the exception stays in the log"
    assert_enqueued_jobs 1, only: DocumentUnderstandingJob
  end

  test "a persistent provider outage lands the row terminally once the retries are spent" do
    stub_ocr_success(pages: [ { page: 1, text: "TOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT, success: false))

    # Same real-ladder drive as the OCR exhaustion test: no ActiveJob internals.
    perform_enqueued_jobs(only: DocumentUnderstandingJob) do
      DocumentUnderstandingJob.perform_later(@link.id)
    end

    assert_equal "failed", @link.reload.status
    assert_includes @link.failure_message, "AI provider unavailable"
    assert_nil @link.extraction
  end

  test "a non-OCR, non-provider failure holds the row and is never re-raised into an unbounded retry" do
    # Review finding 1: any other exception used to be held AND re-raised. No
    # retry_on matches it, and Sidekiq's default is 25 attempts, so every
    # attempt re-entered through the job's `queued` guard, cleared the hold in
    # mark_processing!, and re-ran the whole read — OCR sidecar plus a paid
    # provider call. A route failure (here: the draft creation raising, as the
    # statement vault's DuplicateUploadError or a PG::UniqueViolation would) must
    # end the attempt, not schedule another paid read. The exception is also
    # kept out of the message the archive renders (cleanup wave): the row gets a
    # plain sentence and the raw exception goes to the log.
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))
    ReceiptImport.stubs(:find_or_create_from_document_link!)
                 .raises(StandardError.new("vault refused: duplicate upload"))

    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      DocumentUnderstandingJob.perform_now(@link.id) # must not raise
    ensure
      Rails.logger = original_logger
    end

    @link.reload
    assert_equal "queued", @link.status
    assert_includes @link.failure_message, "could not be read"
    assert_no_match(/StandardError|duplicate upload/, @link.failure_message,
                    "raw exception text must never reach the user")
    assert_includes log.string, "duplicate upload",
                    "the exception is kept in the log, where it belongs"
    assert_enqueued_jobs 0, only: DocumentUnderstandingJob
  end

  test "validate flags an OCR/model total disagreement" do
    understanding = DocumentUnderstanding.new(RECEIPT)
    validations = DocumentUnderstandingJob.validate(understanding, ocr_text: "ACME STORE\nTOTAL 99.99")

    assert_equal false, validations["totals_agree"]
    assert_equal "12.34", validations["ai_total"]
    assert_equal "99.99", validations["ocr_total"]
  end

  test "validate refuses to pass the line-item sum when any amount is unparseable" do
    # A false pass here is money-relevant (it gates a later auto-post): a
    # dropped, unreadable amount must read as "not checkable", never "agrees".
    understanding = DocumentUnderstanding.new(
      RECEIPT.merge(
        "line_items" => [ { "description" => "Coffee", "amount" => "12.34" },
                          { "description" => "Fee", "amount" => "n/a" } ]
      )
    )
    validations = DocumentUnderstandingJob.validate(understanding, ocr_text: "TOTAL 12.34")

    assert_nil validations["line_items_sum"],
               "an unparseable amount makes the sum uncheckable, never a false pass"
  end

  test "validate reads a mis-grouped amount as unparseable, never a false sum agreement" do
    # Review finding 2: `line_items_sum` used a bare `BigDecimal(amount.delete(","))`
    # with no grouping guard, so "12,34,5" parsed as 12345. With the model's own
    # total also reading 12345, the sum "agreed" on a value nobody could read —
    # a false `true` on the key that gates Milestone B's auto-post. Both sides
    # now go through DocumentUnderstanding.parse_amount and read nil.
    understanding = DocumentUnderstanding.new(
      RECEIPT.merge(
        "total" => "12345",
        "line_items" => [ { "description" => "Fee", "amount" => "12,34,5" } ]
      )
    )
    validations = DocumentUnderstandingJob.validate(understanding, ocr_text: "TOTAL 12345")

    assert_equal "12345.0", validations["ai_total"],
                 "the model's total is a well-formed 12345 and reads fine"
    assert_nil validations["line_items_sum"],
               "but the mis-grouped line item is uncheckable, never a false pass"
  end

  test "validate accepts agreement and checks the line-item sum and the last4 witness" do
    understanding = DocumentUnderstanding.new(RECEIPT)
    validations = DocumentUnderstandingJob.validate(understanding, ocr_text: "TOTAL 12.34\nCARD 4242")

    assert_equal true, validations["totals_agree"]
    assert_equal true, validations["line_items_sum"]
    assert_equal true, validations["last4_in_ocr"]
  end

  # --- Task 8: the receipt seam -----------------------------------------------

  test "a receipt is routed to a draft and linked to its document" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    assert_difference -> { ReceiptImport.count }, 1 do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    # The brief's fence reads `ReceiptImport.last`, but imports have UUID primary
    # keys — `.last` orders by a random uuid, not by insertion, so it returns a
    # fixture at random. Find the draft by the link the job read instead.
    draft = ReceiptImport.find_by!(document_link_id: @link.id)
    assert_equal @link.id, draft.document_link_id
    assert_equal "understood", draft.understanding_state
    assert_equal BigDecimal("12.34"), draft.total_amount
  end

  test "a routed receipt enqueues the auto-post" do
    # The read never writes money itself (D8): it hands the settled draft to the
    # writer, which re-checks the gate at write time. Enqueued, not run inline.
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    assert_enqueued_with(job: AutoPostReceiptJob) do
      DocumentUnderstandingJob.perform_now(@link.id)
    end
  end

  test "with the household switch off no auto-post is enqueued" do
    Setting.auto_post_receipts = false
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    assert_no_enqueued_jobs(only: AutoPostReceiptJob) do
      DocumentUnderstandingJob.perform_now(@link.id)
    end
  ensure
    Setting.auto_post_receipts = true
  end

  test "a bill is routed but never enqueued for auto-post" do
    # Ruling RB8: a receipt is evidence of payment; a bill is an invoice that may
    # be unpaid. It still lands as a reviewable draft — it just never posts itself.
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("document_class" => "bill")))

    assert_no_enqueued_jobs(only: AutoPostReceiptJob) do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    draft = ReceiptImport.find_by!(document_link_id: @link.id)
    assert_equal "understood", draft.understanding_state, "the bill is still read and reviewable"
    assert_equal "bill", @link.reload.source
  end

  test "re-running the read does not mint a second draft" do
    stub_ocr_success(pages: [ { page: 1, text: "TOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.update!(status: "queued")   # as the reaper would

    assert_no_difference -> { ReceiptImport.count } do
      DocumentUnderstandingJob.perform_now(@link.id)
    end
  end

  test "a routed receipt draft carries the extraction anchor and its item rows carry their page" do
    # Review finding 3: imports.document_extraction_id and import_rows.source_page
    # were written by nothing, so an extracted draft could not trace to the read
    # that produced it (the stated reason document_extractions exists).
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    draft = ReceiptImport.find_by!(document_link_id: @link.id)
    assert_equal @link.extraction.id, draft.document_extraction_id,
                 "the draft traces to the read that produced it (spec §8.3)"
    assert_equal 1, draft.rows.count
    assert_equal 1, draft.rows.first.source_page,
                 "a single-page batch names exactly one page, so the item row carries it"
    assert_nil draft.rows.first.source_coordinates,
               "PaddleOCR's boxes are not linked to the model's rows — never invent one"
  end

  # --- Task 9: the statement seam --------------------------------------------

  test "a statement is routed to a statement-backed draft with its rows" do
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    assert_difference -> { PdfImport.count }, 1 do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    statement = statement_for(@link)
    # The brief's fence reads `PdfImport.last`, but imports have UUID primary
    # keys and test/fixtures/imports.yml holds three PdfImports, so `.last`
    # orders by a random uuid and returns a fixture. Find the import by the
    # statement the job just minted instead — the property under test is the
    # link between the two, not the row order.
    import = PdfImport.find_by!(account_statement_id: statement.id)
    assert_equal statement.id, import.account_statement_id
    # The document anchor (review finding 1): the statement's own rows are born
    # off this import, so it must carry the statement's archived link — or every
    # row reads "from a bank export" with no chip back to the uploaded document.
    assert_equal statement.archived_document_link.id, import.document_link_id,
                 "the statement's import must point at the statement's own document"
    assert_equal 2, import.rows_count
    assert_equal "Chase", statement.institution_name_hint
    assert_equal Date.new(2026, 9, 1), statement.period_start_on
    # The rendered sentence, not the key: the summary is user-visible (the import
    # review screen and the next-steps email) and drives the publish gate
    # (Import#ai_processed? is `ai_summary.present?`).
    assert_equal "Read from this document by AI (Chase).", import.ai_summary
    assert import.ai_processed?
  end

  test "a statement the read could not name still gets a summary, never an empty bank" do
    # institution_name_hint is a hint the model may simply not supply; an empty
    # "()" would be the same class of garbled copy review finding 1 was about.
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT.merge("institution_name" => nil)))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal "Read from this document by AI.", import.ai_summary
    assert import.ai_processed?
  end

  test "a multi-page statement is batched, and the batches are stitched" do
    pages = (1..5).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    seen_batches = []
    provider = FakeProvider.new(STATEMENT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: ""|
      seen_batches << pages.size
      @response
    end
    stub_provider(provider)

    with_batch_size(2) { DocumentUnderstandingJob.perform_now(@link.id) }

    assert_equal [ 2, 2, 1 ], seen_batches, "pages are sent in bounded batches, never all at once"
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 6, import.rows_count, "every batch's transactions are kept"
  end

  test "a continuation batch's rows survive even when that batch is classified other" do
    # Review finding 2 (ruling on finding 4): `part.transactions` is gated on the
    # BATCH's own document_class, and on the generic no-schema read a mid-statement
    # run of continuation pages comes back "other" routinely — so its rows used to
    # vanish with no error and no signal. FakeProvider cannot show this (it returns
    # the identical verdict every call); ScriptedProvider can.
    pages = (1..4).map { |n| { page: n, text: "ACCOUNT SUMMARY\nPAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    continuation = {
      "document_class" => "other",
      "transactions" => [ { "date" => "2026-09-07", "amount" => "-9.99", "name" => "Late Fee", "notes" => "" } ]
    }
    stub_provider(ScriptedProvider.new(STATEMENT, continuation))

    with_batch_size(2) { DocumentUnderstandingJob.perform_now(@link.id) }

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal [ "Cafe", "Fuel", "Late Fee" ], import.rows.order(:source_row_number).pluck(:name),
                 "the continuation batch's rows are the statement's rows, whatever that batch called itself"
    assert_equal 3, import.rows_count
  end

  test "a multi-page receipt keeps the line items of its later batches" do
    # Review finding 3 (ruling on finding 4): understand_in_batches runs for every
    # class, so batching quietly applied to receipts too — while
    # merge_understanding keeps only the FIRST value per field, which threw away
    # every line item past the first batch. For a receipt that is the whole payload.
    pages = (1..2).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    second_page = RECEIPT.merge(
      "line_items" => [ { "description" => "Sandwich", "amount" => "8.00" } ],
      "total" => nil, "date" => nil, "payee" => nil
    )
    stub_provider(ScriptedProvider.new(RECEIPT, second_page))

    with_batch_size(1) { DocumentUnderstandingJob.perform_now(@link.id) }

    draft = ReceiptImport.find_by!(document_link_id: @link.id)
    assert_equal [ "Coffee", "Sandwich" ], draft.line_items.map { |item| item["description"] },
                 "every batch's line items are kept"
    assert_equal "12.34", draft.extracted_data["total"], "the first batch's total still wins"
  end

  test "re-running a statement read adopts the existing import" do
    stub_ocr_success(pages: [ { page: 1, text: "CHASE", confidence: 0.96 } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    @link.update!(status: "queued")   # as the reaper would

    assert_no_difference -> { PdfImport.count } do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    # ...and it ADOPTED that import rather than making a fresh statement+import
    # pair that happened not to change the count. `assert_no_difference` alone
    # passes just as well when the re-run failed to create anything at all, so
    # pin the identity the adoption has to preserve.
    assert_equal import.id, PdfImport.find_by!(account_statement_id: statement_for(@link).id).id
    assert_equal 1, PdfImport.where(account_statement: statement_for(@link)).count
  end

  test "a routed statement import carries the extraction anchor" do
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal @link.extraction.id, import.document_extraction_id,
                 "the statement import traces to the read that produced it (spec §8.3)"
    assert_equal [ 1, 1 ], import.rows.order(:source_row_number).pluck(:source_page),
                 "a single-page batch names exactly one page on every row"
  end

  test "a multi-page statement batch leaves source_page unknown rather than inventing one" do
    # A row read from a batch of two pages could sit on either; a single-page
    # batch is the only one that genuinely names a page, so nothing is written
    # for this one (spec §8.3 — "never a guess").
    pages = (1..2).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal [ nil, nil ], import.rows.order(:source_row_number).pluck(:source_page)
  end

  # --- Task 10: the account resolver ------------------------------------------

  test "a confidently matched account is prefilled without asking" do
    accounts(:credit_card).update!(institution_name: "Chase", last4: "4242", account_network: "visa")
    # The card number is ON the page, so §7.5's witness holds and the last4 term
    # scores; without it the match would sit below the bar (see the gate tests).
    stub_ocr_success(pages: [ { page: 1, text: "ACME\nCARD 4242\nTOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("institution_name" => "Chase")))

    DocumentUnderstandingJob.perform_now(@link.id)

    # The brief reads ReceiptImport.last, but imports have UUID primary keys and
    # test/fixtures/imports.yml holds two ReceiptImports (one of them
    # account-bearing), so `.last` orders by a random uuid and can return a
    # fixture. Find the draft the job read by its document link instead.
    assert_equal accounts(:credit_card).id, ReceiptImport.find_by!(document_link_id: @link.id).account_id
  end

  test "a below-bar match leaves the account blank for the step-3 ask" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME\nTOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("institution_name" => "Nothing Like Any Account")))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil ReceiptImport.find_by!(document_link_id: @link.id).account_id
  end

  test "a match above the floor but below the bar still leaves the account blank" do
    # The below-bar test above uses hints NO account can score on, so every
    # candidate is dropped by the FLOOR (0.35) and deleting the bar gate would
    # leave the suite green. Here the account scores exactly 0.40 — institution
    # (0.35) + currency (0.05), with NO last4 at all (an unwitnessed last4
    # contributes nothing — see the witness gate) — which is above the floor and
    # below the bar (0.60). Only the bar keeps the account blank.
    accounts(:credit_card).update!(institution_name: "Chase", last4: nil)
    stub_ocr_success(pages: [ { page: 1, text: "CHASE\nTOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("institution_name" => "Chase", "card_last4" => nil)))

    prefill_match = Account::DocumentMatcher.best_match(
      family: @family, institution_hint: "Chase", currency: "USD"
    )
    assert_equal "0.4".to_d, prefill_match.confidence,
                 "the fixture must sit above the floor, or the floor — not the bar — is what drops it"

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil ReceiptImport.find_by!(document_link_id: @link.id).account_id
  end

  test "a confidently matched statement prefills on the statement-backed draft" do
    accounts(:depository).update!(institution_name: "Chase", last4: "1234")
    # "1234" is on the page, so the account-number last4 the read reports passes
    # the §7.5 witness and the statement prefills.
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE 1234", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal accounts(:depository).id, import.account_id
  end

  test "a seeded last4 backed by the OCR witness prefills without asking" do
    # The document-only read: no institution to lean on, so the only signal is
    # the card number the page carries. Spec §7.5's second witness — the last4
    # actually present in the OCR text — is what lets the column match clear the
    # prefill bar instead of sitting below it.
    accounts(:credit_card).update!(last4: "4242", institution_name: nil)
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nCARD 4242\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal accounts(:credit_card).id, ReceiptImport.find_by!(document_link_id: @link.id).account_id
  end

  test "a seeded last4 the OCR never saw leaves the account blank for the ask" do
    accounts(:credit_card).update!(last4: "4242", institution_name: nil)
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil ReceiptImport.find_by!(document_link_id: @link.id).account_id
  end

  test "the read prefers the card's last4 over the account-number last4" do
    # The live read reported card_last4 "7891" (the card) and account_last4
    # "7512" (the account number). Resolving on the account number would file
    # the statement under the wrong identity; the card's own last4 wins.
    accounts(:credit_card).update!(last4: "7891", institution_name: nil)
    accounts(:depository).update!(last4: "7512", institution_name: nil)
    verdict = STATEMENT.merge("institution_name" => nil, "account_last4" => "7512", "card_last4" => "7891")
    stub_ocr_success(pages: [ { page: 1, text: "CARD 7891\nACCOUNT 7512", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(verdict))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal accounts(:credit_card).id, import.account_id
  end

  test "an unwitnessed last4 never drives a prefill, even beside a matching institution" do
    # Spec §7.5: a last4 match MUST ALSO appear in the OCR text. The page here
    # carries no "4242", so the validly-typed digit contributes nothing and the
    # match sits at institution (0.35) + currency (0.05) = 0.40, below the bar.
    accounts(:credit_card).update!(institution_name: "Triangle", last4: "4242")
    stub_ocr_success(pages: [ { page: 1, text: "TRIANGLE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("institution_name" => "Triangle")))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil ReceiptImport.find_by!(document_link_id: @link.id).account_id
  end

  test "the vault stores the CARD's last4 so the matcher suggests the seeded account" do
    # The in-scope Triangle case: card "7891", account number "7512", an account
    # seeded with the card's last4. The hint must be the CARD number, or the
    # vault matcher scores bank digits against a card column and suggests nothing.
    accounts(:credit_card).update!(last4: "7891", institution_name: nil)
    accounts(:depository).update!(last4: "7512", institution_name: nil)
    verdict = STATEMENT.merge("institution_name" => nil, "account_last4" => "7512", "card_last4" => "7891")
    # "7891" is NOT on the page, so the resolver does not prefill; the statement
    # stays unmatched and must still carry the suggestion the vault matcher
    # derives from the stored hint.
    stub_ocr_success(pages: [ { page: 1, text: "STATEMENT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(verdict))

    DocumentUnderstandingJob.perform_now(@link.id)

    statement = statement_for(@link)
    assert_equal "7891", statement.account_last4_hint,
                 "the card number, not the account number, is the seeded identity"
    assert_equal accounts(:credit_card), statement.suggested_account
  end

  # --- Task 11: what a read teaches, and only on a human's word ----------------

  test "an unconfirmed read never teaches the account its card identity" do
    # Spec N14: the account learns from the first CONFIRMED match. The read alone
    # is the AI's guess — even a read carrying a card_last4 — and writing durable
    # identity from it would launder that guess into state the fill-only rule then
    # makes permanent. This pins the assent line: the job never writes here; only
    # the step-3 confirm (Import::AccountsController#update) does.
    account = accounts(:credit_card)
    account.update!(last4: nil, account_network: nil)
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("card_network" => "visa")))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil account.reload.last4, "only a human's confirmation writes durable identity"
    assert_nil account.account_network
  end

  # --- Task 11 fix round 1: the read heartbeat ---------------------------------

  test "each batch heartbeats the row so a long read never looks stale" do
    # The reaper selects on a stale `updated_at`, and a read that outlives the
    # bound must not be re-enqueued while it is still running (a second OCR run,
    # a second paid provider call, a second extraction). The job touches the row
    # as it works; this pins the touch at the batch seam, where a long read
    # spends most of its time.
    pages = (1..2).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.9, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    link_id = @link.id
    observed_second_batch = nil
    calls = 0
    provider = FakeProvider.new(STATEMENT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: ""|
      calls += 1
      if calls == 1
        # Simulate the read outliving the bound: by the next batch the row's
        # clock is hours old unless the job refreshes it between batches.
        DocumentLink.where(id: link_id).update_all(updated_at: 2.hours.ago)
      else
        observed_second_batch = DocumentLink.find(link_id).updated_at
      end
      @response
    end
    stub_provider(provider)

    with_batch_size(1) { DocumentUnderstandingJob.perform_now(@link.id) }

    assert observed_second_batch > 30.minutes.ago,
           "a batch must refresh the row's clock, or the reaper re-enqueues a live read"
  end

  # --- Task 2: the statement permission moves to the vault row ----------------

  test "a statement uploaded by someone who cannot manage statements gets no vault row" do
    # The intake no longer asks the user what a document is, so the old tile-time
    # guard had nothing to test at staging time. The refusal now belongs where
    # the vault row would be created: the document is still read, archived and
    # visible, but no vault row is minted for an uploader who may not manage
    # statements (the brief's `users(:family_guest)` does not exist; the guest
    # fixture in this repo is `intro_user`, role "guest").
    @link.update!(created_by: users(:intro_user))
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    assert_no_difference -> { AccountStatement.count } do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    assert_equal "queued", @link.reload.status
    assert_includes @link.failure_message, "statement"
  end

  test "a statement uploaded by a statement manager does get its vault row" do
    @link.update!(created_by: users(:family_admin))
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96 } ])
    stub_provider(FakeProvider.new(STATEMENT))

    assert_difference -> { AccountStatement.count }, 1 do
      DocumentUnderstandingJob.perform_now(@link.id)
    end
  end

  def statement_for(link)
    AccountStatement.find_by(id: link.reload.account_statement_id)
  end

  # The batch size is a constant read at call time, so it can be pinned in a test.
  def with_batch_size(size)
    original = DocumentUnderstandingJob::PAGE_BATCH
    DocumentUnderstandingJob.send(:remove_const, :PAGE_BATCH)
    DocumentUnderstandingJob.const_set(:PAGE_BATCH, size)
    yield
  ensure
    DocumentUnderstandingJob.send(:remove_const, :PAGE_BATCH)
    DocumentUnderstandingJob.const_set(:PAGE_BATCH, original)
  end
end
