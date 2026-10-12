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
    @link = DocumentLink.create!(family: @family, source: "other", status: "queued",
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
    assert_includes @link.failure_message, "found no text"
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
    assert_includes @link.failure_message, "found no text"
    assert_nil @link.extraction
    assert_not_nil @link.stored_path
  end

  test "an unreachable OCR service leaves the row mid-read for the retry, never settles it" do
    stub_request(:post, "#{Ocr.url}/ocr").to_raise(Faraday::ConnectionFailed.new("refused"))
    stub_provider(FakeProvider.new(RECEIPT))

    # retry_on swallows the error and re-enqueues rather than letting it escape,
    # so the assertion is on the state it leaves behind, not on a raised class.
    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "processing", @link.reload.status
    assert_enqueued_jobs 1, only: DocumentUnderstandingJob
    assert_nil @link.extraction, "a failed read must not record a verdict"
  end

  test "a persistent OCR outage lands the row terminally once the retries are spent" do
    stub_request(:post, "#{Ocr.url}/ocr").to_raise(Faraday::ConnectionFailed.new("refused"))
    stub_provider(FakeProvider.new(RECEIPT))

    # The retry counter is already at the ceiling when the failure handler runs
    # (the retry_on block fires instead of re-enqueueing) — the terminal state
    # the per-attempt test above does not reach. Rails 8.1 tracks retries per
    # exception class in `exception_executions`, keyed by the exception list's
    # `to_s`; attempts: 8, and the handler adds one more.
    job = DocumentUnderstandingJob.new(@link.id)
    job.exception_executions = { "[Ocr::Error]" => 7 }
    job.perform_now

    assert_equal "failed", @link.reload.status
    assert_includes @link.failure_message, "unreachable"
    assert_nil @link.extraction
  end

  test "a failed provider call holds the row rather than settling it" do
    stub_ocr_success(pages: [ { page: 1, text: "TOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT, success: false))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "queued", @link.reload.status
    assert_includes @link.failure_message, "AI provider failed"
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

  test "re-running the read does not mint a second draft" do
    stub_ocr_success(pages: [ { page: 1, text: "TOTAL 12.34", confidence: 0.97 } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)
    @link.update!(status: "queued")   # as the reaper would

    assert_no_difference -> { ReceiptImport.count } do
      DocumentUnderstandingJob.perform_now(@link.id)
    end
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
    assert_equal 2, import.rows_count
    assert_equal "Chase", statement.institution_name_hint
    assert_equal Date.new(2026, 9, 1), statement.period_start_on
    # The rendered sentence, not the key: the summary is user-visible (the import
    # review screen and the next-steps email) and drives the publish gate
    # (Import#ai_processed? is `ai_summary.present?`), and the paperless/template
    # wording it used to borrow rendered as "…template vperiod (paperless OCR)".
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

  # --- Task 10: the account resolver ------------------------------------------

  test "a confidently matched account is prefilled without asking" do
    accounts(:credit_card).update!(institution_name: "Chase", last4: "4242", account_network: "visa")
    stub_ocr_success(pages: [ { page: 1, text: "ACME\nTOTAL 12.34", confidence: 0.97 } ])
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

  test "a confidently matched statement prefills on the statement-backed draft" do
    accounts(:depository).update!(institution_name: "Chase", last4: "1234")
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal accounts(:depository).id, import.account_id
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
