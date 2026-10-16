require "test_helper"
require "yaml"

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
    def understand_document(pages:, ocr_text:, family: nil, model: "", rows_expected: true) = @response
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
    assert_equal "failed", @link.extraction.status, "the hold is kept on a failed read record"
    assert_empty @link.extraction.verdict, "an unreadable document records no verdict"
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
    assert_equal "failed", @link.extraction.status, "the hold is kept on a failed read record"
    assert_empty @link.extraction.verdict, "an unreadable document records no verdict"
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

  test "a failed provider call holds the row with a sentence and schedules no retry of the same provider" do
    # Spec §2: a provider failure moves to the next reader instead of retrying
    # the same one eight times; with no other reader the row is held once. The
    # owner reads a sentence; the provider's raw message stays in the log.
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

    assert_equal "queued", @link.status
    assert_includes @link.failure_message, "Nothing was imported"
    assert_no_match(/AI provider failed/, @link.failure_message,
                    "the provider's raw message must not reach the user")
    assert_includes log.string, "AI provider failed", "the exception stays in the log"
    assert_no_enqueued_jobs only: DocumentUnderstandingJob
  end

  # --- The reader ladder (spec §2/§3) ---

  class NamedProvider < FakeProvider
    def initialize(name, verdict, success: true)
      super(verdict, success: success)
      @provider_name = name
      @llm_model = "#{name}-model"
    end
  end

  def reader(name, verdict, kind: :cloud, success: true, guard: nil)
    DocumentReaderLadder::Reader.new(provider: NamedProvider.new(name, verdict, success: success),
                                     kind: kind, label: name, guard: guard)
  end

  def local_guard = LocalLlm::GpuGuard.new(base_url: "http://ollama:11434/v1", model: "qwen2.5vl:7b")

  def stub_ladder(*readers)
    DocumentReaderLadder.stubs(:for).returns(readers)
  end

  def attempts(link = @link) = link.reload.extraction.validations["read_attempts"]

  # The owner's rule for receipts: the text reader first. A receipt whose own
  # arithmetic proves it needs no model at all.
  test "a receipt the text proves is read with no model call" do
    stub_ocr_success(pages: [ { page: 1, text: file_fixture("receipts/grocery.txt").read, confidence: 0.97, image: "aGk=" } ])
    provider = FakeProvider.new(RECEIPT)
    provider.expects(:understand_document).never
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    draft = ReceiptImport.find_by!(document_link: @link)
    assert_equal BigDecimal("11.92"), draft.total_amount
    assert_equal Date.new(2026, 9, 14), draft.purchase_date
    assert_equal "text reader", @link.reload.extraction.provider
  end

  test "when the model is asked, the reader's total and date beat the model's" do
    stub_ocr_success(pages: [ { page: 1, text: file_fixture("receipts/fuel.txt").read, confidence: 0.97, image: "aGk=" } ])
    stub_provider(FakeProvider.new(RECEIPT.merge("total" => "99.99", "date" => "2026-01-01", "payee" => "Petro-Canada")))

    DocumentUnderstandingJob.perform_now(@link.id)

    draft = ReceiptImport.find_by!(document_link: @link)
    assert_equal BigDecimal("62.53"), draft.total_amount, "the printed TOTAL, not the model's"
    assert_equal Date.new(2026, 9, 28), draft.purchase_date
    assert_equal "Petro-Canada", draft.payee, "the store name may come from the model"
    # Review C1: the total check compares the MODEL with the text — the gate on
    # receipt auto-post — never the text with itself.
    assert_equal false, @link.reload.extraction.validations["totals_agree"]
  end

  test "a receipt read from its text alone has no model to agree with, so never auto-posts on it" do
    stub_ocr_success(pages: [ { page: 1, text: file_fixture("receipts/grocery.txt").read, confidence: 0.97, image: "aGk=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil @link.reload.extraction.validations["totals_agree"]
  end

  test "a busy GPU skips the local reader and the cloud reads the document" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    guard = local_guard
    guard.stubs(:busy?).returns(true)
    guard.expects(:unload!).never
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard), reader("DeepSeek", RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "DeepSeek", @link.reload.extraction.provider
    assert_equal %w[skipped_busy read], attempts.map { |attempt| attempt["outcome"] }
    assert_equal "unlinked", @link.status
  end

  test "a retry the owner chose with the local model reads with it when the GPU is free" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    guard = local_guard
    guard.stubs(:busy?).returns(false)
    guard.stubs(:unload!).returns(true)
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard))

    DocumentUnderstandingJob.perform_now(@link.id, "local")

    assert_equal "local", @link.reload.extraction.provider
  end

  # Gap 8: a batch of uploads unloaded and reloaded the model for every
  # document. It stays loaded while more documents wait, and leaves after the last.
  test "the local model stays loaded while another document is waiting" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    waiting = DocumentLink.create!(family: @family, source: "receipt", status: "queued", original_filename: "next.png")
    waiting.stage!(io: StringIO.new("PNG-next"), filename: "next.png", content_type: "image/png")
    guard = local_guard
    guard.stubs(:busy?).returns(false)
    guard.stubs(:loaded?).returns(false)
    guard.expects(:unload!).never
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "local", @link.reload.extraction.provider
  end

  # Gap 9: an unexpected error says what it was, in plain words.
  test "a save that fails says so instead of a bare could-not-be-read" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_provider(FakeProvider.new(RECEIPT))
    ReceiptImport.stubs(:find_or_create_from_document_link!).raises(ActiveRecord::RecordInvalid.new(ReceiptImport.new))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_includes @link.reload.failure_message, "couldn't save"
  end

  test "a model that was already resident is left loaded when the read ends" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    guard = local_guard
    guard.stubs(:busy?).returns(false)
    guard.stubs(:loaded?).returns(true)
    guard.expects(:unload!).never
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "local", @link.reload.extraction.provider
  end

  # Review finding I3: "Retry with local model" waits its turn for the GPU
  # (spec §6) rather than queueing a call that times out behind another model.
  test "a manual local retry waits for a busy GPU to free up, then reads" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    guard = local_guard
    guard.expects(:busy?).times(3).returns(true, true, false)
    guard.stubs(:loaded?).returns(false)
    guard.stubs(:unload!).returns(true)
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard))
    DocumentUnderstandingJob.any_instance.stubs(:sleep)

    DocumentUnderstandingJob.perform_now(@link.id, "local")

    assert_equal "local", @link.reload.extraction.provider
  end

  test "a manual local retry gives up when the GPU stays busy past its budget" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    Setting.stubs(:local_llm_document_budget).returns(0)
    guard = local_guard
    guard.stubs(:busy?).returns(true)
    guard.expects(:unload!).never
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard))
    DocumentUnderstandingJob.any_instance.stubs(:sleep)

    DocumentUnderstandingJob.perform_now(@link.id, "local")

    assert_equal %w[skipped_busy], attempts.map { |attempt| attempt["outcome"] }
    assert_equal "gpu_busy", @link.reload.hold_reason.code
  end

  test "the local model is unloaded once when its read ends, even when it failed" do
    DocumentLink.where.not(id: @link.id).update_all(status: "unlinked") # nothing else waits for the GPU
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    guard = local_guard
    guard.stubs(:busy?).returns(false)
    guard.expects(:unload!).once.returns(true)
    stub_ladder(reader("local", RECEIPT, kind: :local, success: false, guard: guard), reader("DeepSeek", RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal %w[failed read], attempts.map { |attempt| attempt["outcome"] }
  end

  test "a cloud reader's error moves to the next reader instead of scheduling a retry" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_ladder(reader("DeepSeek", RECEIPT, success: false), reader("Gemini", RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "Gemini", @link.reload.extraction.provider
    assert_no_enqueued_jobs only: DocumentUnderstandingJob
  end

  # Review finding (promoted): output a reader cannot turn into a read is that
  # reader failing — the next reader reads, and the model is not asked twice.
  test "a reader whose output breaks the read moves to the next reader, asked once" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    broken = reader("DeepSeek", RECEIPT)
    broken.provider.expects(:understand_document).once.raises(NoMethodError.new("undefined method 'fetch' for nil"))
    stub_ladder(broken, reader("Gemini", RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "Gemini", @link.reload.extraction.provider
    assert_equal %w[failed read], attempts.map { |attempt| attempt["outcome"] }
  end

  test "a local read past its document budget is abandoned for the next reader" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    Setting.stubs(:local_llm_document_budget).returns(0)
    guard = local_guard
    guard.stubs(:busy?).returns(false)
    guard.stubs(:unload!).returns(true)
    stub_ladder(reader("local", RECEIPT, kind: :local, guard: guard), reader("DeepSeek", RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal %w[timed_out read], attempts.map { |attempt| attempt["outcome"] }
  end

  test "statement rows that don't add up move to the next reader, whose rows route" do
    off_by_one = PRINTED_SIGN_STATEMENT.merge("transactions" => PRINTED_SIGN_STATEMENT["transactions"].map { |row| row.merge("amount" => "1.00") })
    stub_ocr_success(pages: [ { page: 1, text: SCAN_TOTALS_TEXT, confidence: 0.96, image: "aGk=" } ])
    stub_ladder(reader("DeepSeek", off_by_one), reader("Gemini", PRINTED_SIGN_STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal %w[did_not_add_up read], attempts.map { |attempt| attempt["outcome"] }
    assert_equal "Gemini", @link.extraction.provider
    assert imported_signed_amounts(@link)["PAYMENT THANK YOU"].negative?
  end

  test "when no reader's rows add up, the fullest read still goes to review" do
    short = PRINTED_SIGN_STATEMENT.merge("transactions" => PRINTED_SIGN_STATEMENT["transactions"].first(1).map { |row| row.merge("amount" => "1.00") })
    wrong = PRINTED_SIGN_STATEMENT.merge("transactions" => PRINTED_SIGN_STATEMENT["transactions"].map { |row| row.merge("amount" => "2.00") })
    stub_ocr_success(pages: [ { page: 1, text: SCAN_TOTALS_TEXT, confidence: 0.96, image: "aGk=" } ])
    stub_ladder(reader("DeepSeek", short), reader("Gemini", wrong))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal %w[did_not_add_up did_not_add_up], attempts.map { |attempt| attempt["outcome"] }
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 3, import.rows_count, "the read with the most rows routes for review"
    assert_equal "pending", import.status, "it waits for the owner; nothing posts"
    assert_equal false, @link.extraction.validations["statement_totals_reconcile"]
  end

  # Gap 3 from the owner's batch: with no totals on the page to check against,
  # the local model's read was accepted unchecked and the cloud never ran.
  test "an unverifiable statement read moves on so the cloud reader gets a turn" do
    local_rows = STATEMENT.merge("transactions" => [ { "date" => "2026-09-03", "amount" => "-1.00", "name" => "Cafe", "notes" => "" } ])
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_ladder(reader("local", local_rows), reader("DeepSeek", STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal %w[unverified unverified], attempts.map { |attempt| attempt["outcome"] }
    assert_equal "DeepSeek", @link.extraction.provider, "the stronger, later reader's read routes"
    assert_equal 2, PdfImport.find_by!(account_statement_id: statement_for(@link).id).rows_count
    assert_nil @link.extraction.validations["statement_totals_reconcile"], "unverified is never reconciled"
  end

  test "two readers that agree row for row corroborate an unverifiable read" do
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_ladder(reader("local", STATEMENT), reader("DeepSeek", STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal true, @link.reload.extraction.validations["statement_rows_corroborated"]
  end

  test "when every reader fails the row is held once with each reader's outcome" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_ladder(reader("DeepSeek", RECEIPT, success: false), reader("Gemini", RECEIPT, success: false))

    DocumentUnderstandingJob.perform_now(@link.id)

    @link.reload
    assert_equal "queued", @link.status
    assert @link.failure_message.present?
    assert_no_enqueued_jobs only: DocumentUnderstandingJob
    assert_equal "failed", @link.extraction.status
    assert_equal %w[failed failed], attempts.map { |attempt| attempt["outcome"] }
    assert_equal %w[DeepSeek Gemini], attempts.map { |attempt| attempt["reader"] }
  end

  test "a retry reads the cached OCR instead of running OCR again" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_ladder(reader("DeepSeek", RECEIPT, success: false))
    DocumentUnderstandingJob.perform_now(@link.id)
    assert_requested :post, "#{Ocr.url}/ocr", times: 1

    stub_ladder(reader("Gemini", RECEIPT))
    DocumentUnderstandingJob.perform_now(@link.id, "online")

    assert_requested :post, "#{Ocr.url}/ocr", times: 1
    assert_equal "Gemini", @link.reload.extraction.provider
  ensure
    DocumentLink::OcrCache.delete(@link)
  end

  test "with no reader at all the row is held with the no-provider reason" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_ladder

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "queued", @link.reload.status
    assert_includes @link.failure_message, "No AI reader is set up"
  end

  # --- Holds explain themselves (spec §6) ---

  test "a ladder failure leaves a hold that names each reader and offers both retries" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "aGk=" } ])
    stub_ladder(reader("DeepSeek", RECEIPT, success: false))
    DocumentReaderLadder.stubs(:for).with(mode: "local").returns([ :local ])
    DocumentReaderLadder.stubs(:for).with(mode: "online").returns([ :cloud ])

    DocumentUnderstandingJob.perform_now(@link.id)

    hold = @link.reload.hold_reason
    assert_equal "all_readers_failed", hold.code
    assert_equal %w[retry_local retry_online], hold.actions
    assert_equal hold.message, @link.failure_message
    assert_equal "failed", @link.extraction.status
  end

  test "a text-layer drift hold is stored on the read it came from" do
    stage_pdf(@link, "synthetic_statement_drift.pdf")
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    hold = @link.reload.hold_reason
    assert_equal "statement_drift", hold.code
    assert_includes hold.message, "purchases read $750.00 vs $350.00 stated"
    assert_equal "succeeded", @link.extraction.status, "the read itself worked; its check is what held it"
  end

  test "an unreadable document's hold offers a retry" do
    stub_request(:post, "#{Ocr.url}/ocr").to_return(status: 422, body: { detail: "cannot render" }.to_json,
                                                     headers: { "Content-Type" => "application/json" })
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "ocr_unreadable", @link.reload.hold_reason.code
    assert_includes @link.hold_reason.actions, "retry"
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
    assert_includes @link.failure_message, "stopped the read"
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

  test "a statement whose rows land in line_items still produces the rows and marks the fallback" do
    # The live local model (qwen2.5vl:7b) reads a statement's table correctly but
    # files every row under line_items, leaving transactions empty — its field
    # choice varies run to run, which is exactly why the live read kept returning
    # different counts. The app must adopt those rows as the statement's rows (not
    # drop the money) and record that it did, so the fallback is visible.
    stub_ocr_success(pages: [ { page: 1, text: "ANTHROPIC -16.52\nDEEPSEEK -15.23", confidence: 0.96, image: "aGk=" } ])
    misfiled = STATEMENT.merge(
      "transactions" => [],
      "line_items" => [
        { "description" => "ANTHROPIC SAN FRANCISCOC A", "amount" => "-16.52" },
        { "description" => "DEEPSEERWEA", "amount" => "-15.23" }
      ]
    )
    stub_provider(FakeProvider.new(misfiled))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 2, import.rows_count, "the misfiled rows are the statement's rows, not zero"
    rows = import.rows.order(:source_row_number)
    assert_equal [ "ANTHROPIC SAN FRANCISCOC A", "DEEPSEERWEA" ], rows.pluck(:name),
                 "each line_item's description is the row's name"
    assert_equal [ "-16.52", "-15.23" ], rows.pluck(:amount)
    assert rows.all? { |row| row.date.blank? },
           "a line item carries no date; the row's date is left unknown, never invented"

    validations = @link.extraction.validations
    assert_equal true, validations["statement_rows_from_line_items"],
                 "the fallback is recorded, not silent"
    assert_equal false, validations["statement_rows_have_dates"],
                 "the date-less rows are surfaced, not hidden"
  end

  test "a statement whose pages' models chose different fields keeps every page's rows" do
    # The read is one page per call, and the model's field choice varies per call:
    # page 1's rows land in transactions, page 2's in line_items. The document-level
    # fallback alone drops page 2 (transactions is non-empty, masking it) and the
    # panel stays green — the exact silent loss this wave exists to close. The
    # per-batch pick keeps both.
    pages = (1..2).map { |n| { page: n, text: "ACCOUNT SUMMARY\nPAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)
    transactions_page = STATEMENT.merge(
      "transactions" => [ { "date" => "2026-09-03", "amount" => "-12.34", "name" => "Cafe", "notes" => "" } ],
      "line_items" => []
    )
    line_items_page = STATEMENT.merge(
      "transactions" => [],
      "line_items" => [ { "description" => "Fuel", "amount" => "-50.00" } ]
    )
    stub_provider(ScriptedProvider.new(transactions_page, line_items_page))

    with_batch_size(1) { DocumentUnderstandingJob.perform_now(@link.id) }

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal [ "Cafe", "Fuel" ], import.rows.order(:source_row_number).pluck(:name),
                 "both pages' rows survive, whatever field each page's model used"
    assert_equal 2, import.rows_count

    validations = @link.extraction.validations
    assert_equal true, validations["statement_rows_from_line_items"],
                 "the misfiled page is flagged, not masked by the other page's transactions"
    assert_equal false, validations["statement_rows_have_dates"],
                 "the date-less page is surfaced, computed over the stitched rows"
  end

  test "a statement read into transactions keeps its dated rows and is not marked" do
    # The normal case: rows in transactions, each with a date. Nothing here may be
    # disturbed by the fallback, and neither marker fires.
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal [ Date.new(2026, 9, 3), Date.new(2026, 9, 5) ].map { |d| d.strftime(@family.date_format) },
                 import.rows.order(:source_row_number).pluck(:date)

    validations = @link.extraction.validations
    assert_equal false, validations["statement_rows_from_line_items"]
    assert_equal true, validations["statement_rows_have_dates"]
  end

  test "a receipt's line_items are unchanged and never marked as a statement fallback" do
    stub_ocr_success(pages: [ { page: 1, text: "ACME STORE\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ])
    stub_provider(FakeProvider.new(RECEIPT))

    DocumentUnderstandingJob.perform_now(@link.id)

    draft = ReceiptImport.find_by!(document_link_id: @link.id)
    assert_equal [ "Coffee" ], draft.line_items.map { |item| item["description"] },
                 "a receipt's line items are its payload and stay line items"
    validations = @link.extraction.validations
    assert_equal false, validations["statement_rows_from_line_items"]
    assert_nil validations["statement_rows_have_dates"],
               "a receipt has no statement rows, so the date check does not apply"
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
    # for this one (spec §8.3 — "never a guess"). The default is now one page
    # per call (wave 6), so this is the CONFIGURED multi-page case.
    pages = (1..2).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)
    stub_provider(FakeProvider.new(STATEMENT))

    with_batch_size(2) { DocumentUnderstandingJob.perform_now(@link.id) }

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal [ nil, nil ], import.rows.order(:source_row_number).pluck(:source_page)
  end

  # --- Wave 8: the deterministic statement reader seam -------------------------

  test "a statement PDF with a usable text layer routes the reader's rows, not the model's" do
    # The first test that exercises the reader END TO END: a real text-layer PDF
    # whose rows reconcile against its own printed totals. The model returns a
    # DIFFERENT row, so if the model's row routes the reader did not win.
    stage_pdf(@link, "synthetic_statement.pdf")
    model = STATEMENT.merge("transactions" => [ { "date" => "2026-09-30", "amount" => "-1.00", "name" => "MODEL ROW", "notes" => "" } ])
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(model))

    assert_difference -> { PdfImport.count }, 1 do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 9, import.rows_count, "the reader's 9 rows route, not the model's 1"
    names = import.rows.order(:source_row_number).pluck(:name)
    assert_not_includes names, "MODEL ROW", "the model's rows must not route"
    assert_includes names, "TEST MART MISSISSAUGA ON HILLPA"

    validations = @link.extraction.validations
    assert_equal true, validations["statement_totals_reconcile"]
    assert_equal true, validations["statement_rows_missing_dates"]
    assert_equal 9, validations["statement_row_count"]
    assert_equal "text_layer", validations["statement_rows_source"]

    # R-W8B17: the model's OWN read stays recoverable on `raw_response`, even
    # though the reader's rows are what the verdict (and the route) carried.
    assert_equal [ "MODEL ROW" ], @link.extraction.raw_response["transactions"].map { |row| row["name"] }
  end

  test "a deterministic statement read writes the statement's printed balances onto the record (W8-I)" do
    # The reader parses the statement's OWN figures ("Balance from your last
    # statement" -> opening, "Your New Balance" -> closing) into `stated_totals`.
    # Nothing wrote them onto the vault row, so its opening_balance/closing_balance
    # stayed nil and the statement page's reconciliation could never run. This is
    # the seam: the parsed figures land on the record.
    stage_pdf(@link, "synthetic_statement.pdf")
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    statement = statement_for(@link)
    assert_equal 6000.00.to_d, statement.opening_balance,
                 "the printed 'Balance from your last statement' is written verbatim, never computed"
    assert_equal 1196.78.to_d, statement.closing_balance,
                 "the printed 'Your New Balance' is written verbatim"

    # Idempotent: a re-read adopts the SAME statement row and updates the same two
    # columns — it never mints a second row.
    @link.update!(status: "queued")
    DocumentUnderstandingJob.perform_now(@link.id)

    reread = statement_for(@link)
    assert_equal statement.id, reread.id, "a re-read adopts the statement it already made"
    assert_equal 6000.00.to_d, reread.opening_balance
    assert_equal 1196.78.to_d, reread.closing_balance
  end

  test "a statement read with no parsed totals leaves the printed-balance columns unset (W8-I)" do
    # The OCR text prints no opening or new balance and there is no deterministic
    # rung to read one from, so the reader parses neither figure. The columns must
    # stay nil: an absent parse is never back-filled from the ledger or a guess —
    # a wrong printed balance is worse than a missing one.
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    statement = statement_for(@link)
    assert_nil statement.opening_balance, "no parsed opening -> the column is left unset"
    assert_nil statement.closing_balance, "no parsed closing -> the column is left unset"
  end

  test "a fall-back read still writes the printed opening balance it parsed (W8-I)" do
    # `record_stated_balances` must run for ANY read that parsed a figure, not
    # only a reconciled one. A text-layer read the reader cannot balance
    # (`:unreconcilable`) may still have read the statement's printed opening, and
    # that figure belongs on the record. The code does this correctly today, but
    # every W8-I test above uses a RECONCILED read — so a future `if read.reconciled?`
    # gate around the write would keep them all green and silently drop this case.
    stage_pdf(@link, "synthetic_statement.pdf")
    fallback_text = [
      "For the period: September 9, 2026 to October 8, 2026",
      "Balance from your last statement 6,000.00",
      "Purchases",
      "   Sep 08            Sep 09        MERCHANT ONE                                                     10.00"
    ].join("\n")
    StatementRead::PdfTextLayer.stubs(:for).returns(
      StatementRead::PdfTextLayer::Result.new(text: fallback_text, font_count: 1, usable: true)
    )
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    detail = @link.extraction.validations["statement_read"]
    assert_equal "unreconcilable", detail["verdict"], "the read fell back; it did not reconcile"
    assert_equal "text_layer", detail["source"]
    assert_equal "6000.0", detail["stated_totals"]["opening"], "the printed opening was parsed"

    statement = statement_for(@link)
    assert_equal 6000.00.to_d, statement.opening_balance,
                 "a fall-back read's parsed opening is written, exactly as a reconciled read's is"
    assert_nil statement.closing_balance, "only the parsed figure is written; the unparsed one stays nil"
  end

  test "when the reader supplies the rows, the model's line_items fallback is not claimed (R-W8B12)" do
    # The model files its rows under line_items (transactions empty), which
    # without the reader sets the fallback flag — a mixed-provenance green. The
    # reader's rows are the routed rows, so the flag must NOT claim the model's.
    stage_pdf(@link, "synthetic_statement.pdf")
    misfiled = STATEMENT.merge(
      "transactions" => [],
      "line_items" => [ { "description" => "MODEL ROW", "amount" => "-1.00" } ]
    )
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(misfiled))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 9, import.rows_count
    validations = @link.extraction.validations
    assert_equal false, validations["statement_rows_from_line_items"],
                 "the routed rows are the reader's, not the model's line items"
    assert_equal true, validations["statement_rows_have_dates"]
  end

  test "a trusted deterministic read asks the model for identity only and still routes the reader's rows" do
    # W8-D: when the deterministic reader PROVES the rows, the model must not be
    # asked to enumerate the table — the request goes out identity-only and the
    # reader's rows route. The double records the flag the job sent.
    stage_pdf(@link, "synthetic_statement.pdf")
    seen = []
    provider = FakeProvider.new(STATEMENT.merge(
      "transactions" => [ { "date" => "2026-09-30", "amount" => "-1.00", "name" => "MODEL ROW", "notes" => "" } ]
    ))
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: "", rows_expected: true|
      seen << rows_expected
      @response
    end
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal [ false ], seen,
                 "a trusted deterministic read asks the model for identity only — never the row table"
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 9, import.rows_count, "the reader's proven rows route"
    assert_not_includes import.rows.pluck(:name), "MODEL ROW", "the model's rows must not route"
    assert_equal "text_layer", @link.extraction.validations["statement_rows_source"]
  end

  # The statement prints its own identity; with the rows proven AND the
  # identity complete, nothing is left for a model to read (spec §1).
  IDENTITY_LINES = <<~TEXT
    Account number: 5446 12XX XXXX 1512
    The Triangle Mastercard is issued by Canadian Tire Bank.
  TEXT

  def stage_text_layer_with_identity(link, identity_lines = IDENTITY_LINES)
    stage_pdf(link, "synthetic_statement.pdf")
    text = file_fixture("statements/synthetic_statement.txt").read + "\n" + identity_lines
    StatementRead::PdfTextLayer.stubs(:for).returns(
      StatementRead::PdfTextLayer::Result.new(text: text, font_count: 1, usable: true)
    )
  end

  test "a proven statement with a complete printed identity makes no model call" do
    stage_text_layer_with_identity(@link)
    provider = FakeProvider.new(STATEMENT)
    provider.expects(:understand_document).never
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    statement = statement_for(@link)
    # The first card the page lists is the statement's card identity (the
    # existing "card beats account number" rule); the fixture's cards are 1111/2222.
    assert_equal "1111", statement.account_last4_hint
    assert_equal "1512", @link.extraction.verdict["account_last4"]
    assert_equal "Canadian Tire Bank", statement.institution_name_hint
    assert_equal 9, PdfImport.find_by!(account_statement: statement).rows_count
    assert_equal "text_layer", @link.extraction.validations["identity_source"]
    assert_equal "unlinked", @link.reload.status
  end

  test "every card a statement lists is kept on the statement for account matching" do
    stage_text_layer_with_identity(@link)
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal %w[1111 2222], statement_for(@link).sanitized_parser_output["card_last4s"]
    assert_equal %w[1111 2222 1512], statement_for(@link).sanitized_parser_output["printed_last4s"],
                 "every number the page prints: its cards and its account number"
  end

  # The owner's RBC chequing statements: the layout reads them whole, so they
  # route with no model call, every row signed by the running balance.
  test "an RBC chequing statement routes from its text layer with no model call" do
    stage_pdf(@link, "synthetic_statement.pdf")
    StatementRead::PdfTextLayer.stubs(:for).returns(
      StatementRead::PdfTextLayer::Result.new(text: file_fixture("statements/rbc_chequing_synthetic.txt").read, font_count: 1, usable: true)
    )
    provider = FakeProvider.new(STATEMENT)
    provider.expects(:understand_document).never
    stub_ocr_success(pages: [ { page: 1, text: "RBC", confidence: 0.96, image: "aGk=" } ])
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 18, import.rows_count
    assert_equal true, @link.extraction.validations["statement_totals_reconcile"]
    assert_equal "0001", statement_for(@link).account_last4_hint, "the fixture's account 01234-5550001"
    assert_equal "Royal Bank of Canada", statement_for(@link).institution_name_hint
  end

  # Gap 4: one bad model field held the whole statement.
  test "a statement whose model read has a nonsense currency still routes" do
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT.merge("currency" => "$")))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil @link.reload.failure_message
    assert PdfImport.find_by(account_statement_id: statement_for(@link).id)
  end

  # Spec currency rule: a statement's money is in its account's currency, never
  # the currency a model read off the page.
  test "a statement never takes its currency from the model" do
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT.merge("currency" => "EUR")))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal @family.currency, statement_for(@link).currency, "the family's (then the account's), never the model's EUR"
  end

  # Gap: a read that crashed after creating the statement's vault row left an
  # orphan, and every retry then failed as a duplicate upload of that same file.
  test "a re-read adopts the statement record an earlier, crashed read left behind" do
    stage_pdf(@link, "synthetic_statement.pdf")
    orphan = AccountStatement.create_from_upload!(
      family: @family, account: nil,
      file: Rack::Test::UploadedFile.new(file_fixture("statements/synthetic_statement.pdf"), "application/pdf")
    )
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_nil @link.reload.failure_message
    assert_equal orphan.id, @link.account_statement_id
  end

  # The owner's rule end to end: a proven statement whose printed number the
  # account knows posts itself during the read.
  test "a proven statement for a known account posts itself" do
    accounts(:depository).update!(last4: "0001")
    stage_pdf(@link, "synthetic_statement.pdf")
    StatementRead::PdfTextLayer.stubs(:for).returns(
      StatementRead::PdfTextLayer::Result.new(text: file_fixture("statements/rbc_chequing_synthetic.txt").read, font_count: 1, usable: true)
    )
    stub_ocr_success(pages: [ { page: 1, text: "RBC", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    assert_enqueued_with(job: ImportJob) do
      DocumentUnderstandingJob.perform_now(@link.id)
    end
    assert_equal accounts(:depository), statement_for(@link).account
    assert_equal "importing", PdfImport.find_by!(account_statement_id: statement_for(@link).id).status
  end

  test "the printed identity overrides the model's when the model is still asked" do
    # No issuer line: the identity is incomplete, so the identity-only read runs,
    # but the network the page proves (the 5446 prefix) beats the model's guess.
    stage_text_layer_with_identity(@link, "Account number: 5446 12XX XXXX 1512\n")
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT.merge("card_network" => "amex", "account_last4" => "9999")))

    DocumentUnderstandingJob.perform_now(@link.id)

    verdict = @link.extraction.verdict
    assert_equal "mastercard", verdict["card_network"]
    assert_equal "1512", verdict["account_last4"]
    assert_equal "Chase", verdict["institution_name"], "a field the page lacks still comes from the model"
  end

  test "an untrusted read still asks the model for the statement's rows" do
    # The other half of the conditional ask: with no usable deterministic source
    # the request is today's — rows wanted. A scan (no text layer, no boxes)
    # reaches the vision rung, so the model supplies the rows as it always has.
    seen = []
    provider = FakeProvider.new(STATEMENT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: "", rows_expected: true|
      seen << rows_expected
      @response
    end
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal [ true ], seen, "an untrusted read still requests the statement's rows"
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 2, import.rows_count, "the model's rows route as before"
  end

  # The live trap (2026-10-16): a model reads the statement's OWN printed signs,
  # so a scan whose rows came from the model imported every payment as an
  # expense. The rows are oriented before they route.
  PRINTED_SIGN_STATEMENT = STATEMENT.merge(
    "transactions" => [
      { "date" => "2026-09-03", "amount" => "-500.00", "name" => "PAYMENT THANK YOU", "notes" => "" },
      { "date" => "2026-09-05", "amount" => "15.75", "name" => "Cafe", "notes" => "" },
      { "date" => "2026-09-06", "amount" => "4.25", "name" => "Fuel", "notes" => "" }
    ]
  ).freeze

  SCAN_TOTALS_TEXT = [
    "Balance from your last statement $1,000.00",
    "Total credits -$500.00",
    "Total charges $20.00",
    "Your New Balance $520.00"
  ].join("\n").freeze

  def imported_signed_amounts(link)
    import = PdfImport.find_by!(account_statement_id: statement_for(link).id)
    import.rows.order(:source_row_number).map { |row| [ row.name, row.signed_amount ] }.to_h
  end

  test "a scan's model rows printed in the statement's signs import with a payment as an inflow" do
    stub_ocr_success(pages: [ { page: 1, text: SCAN_TOTALS_TEXT, confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(PRINTED_SIGN_STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    amounts = imported_signed_amounts(@link)
    assert amounts["PAYMENT THANK YOU"].negative?, "a payment is money in (negative entry), got #{amounts['PAYMENT THANK YOU']}"
    assert amounts["Cafe"].positive?, "a purchase is money out"
    assert_equal "flipped", @link.extraction.validations["statement_rows_orientation"]
    assert_equal true, @link.extraction.validations["statement_totals_reconcile"]
  end

  # Review finding C1: equal credits and charges balance in BOTH orientations,
  # so the read is unverified — never "added up", never auto-posted.
  test "a scan whose totals balance either way is not claimed as reconciled" do
    symmetric_text = [
      "Balance from your last statement $100.00", "Total credits -$40.00",
      "Total charges $40.00", "Your New Balance $100.00"
    ].join("\n")
    rows = [
      { "date" => "2026-09-03", "amount" => "-40.00", "name" => "PAYMENT THANK YOU", "notes" => "" },
      { "date" => "2026-09-05", "amount" => "25.00", "name" => "Streaming", "notes" => "" },
      { "date" => "2026-09-06", "amount" => "15.00", "name" => "Music", "notes" => "" }
    ]
    stub_ocr_success(pages: [ { page: 1, text: symmetric_text, confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT.merge("transactions" => rows)))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_not_equal true, @link.reload.extraction.validations["statement_totals_reconcile"]
    assert_equal "keywords", @link.extraction.validations["statement_rows_orientation"]
    assert imported_signed_amounts(@link)["PAYMENT THANK YOU"].negative?, "the credit-named row still orients it"
  end

  test "a scan with no printed totals is oriented by its credit-named rows, unverified" do
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(PRINTED_SIGN_STATEMENT))

    DocumentUnderstandingJob.perform_now(@link.id)

    assert imported_signed_amounts(@link)["PAYMENT THANK YOU"].negative?
    assert_equal "keywords", @link.extraction.validations["statement_rows_orientation"]
  end

  test "a drifting text-layer read holds the link and routes nothing, with the per-check detail" do
    # A mutated copy of the synthetic PDF: its one TEST MART purchase reads
    # 500.00 against the statement's stated 350.00, so the deterministic read
    # CONTRADICTS the statement's own totals. R-W8B19: drift HOLDS and nothing is
    # imported, and the per-check detail must survive for diagnosis.
    stage_pdf(@link, "synthetic_statement_drift.pdf")
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    assert_no_difference -> { PdfImport.count } do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    @link.reload
    assert_equal "queued", @link.status, "the drift holds the row"
    assert_includes @link.failure_message, "purchases read $750.00 vs $350.00 stated",
                    "the hold carries the reader's own sentence"
    assert_nil @link.account_statement_id, "no vault row is minted for a held statement"
    assert_empty PdfImport.where(document_link: @link), "no rows are written"

    validations = @link.extraction.validations
    assert_equal false, validations["statement_totals_reconcile"]
    detail = validations["statement_read"]
    assert_equal "drift", detail["verdict"]
    assert_equal "text_layer", detail["source"]
    assert_equal "drift", detail["checks"]["purchases_sum"]
    assert_equal({ "read" => "750.0", "stated" => "350.0" }, detail["figures"]["purchases_sum"])
    assert_equal "350.0", detail["stated_totals"]["purchases"]
  end

  test "zero rows against non-zero stated totals holds (R-W8B19)" do
    # A text layer that PRINTS totals but yields no dated rows: the statement
    # states money and the reader found none — `:empty_but_expected`, a hold.
    stage_pdf(@link, "synthetic_statement.pdf")
    totals_only = [
      "Statement date: October 8, 2026",
      "For the period: September 9, 2026 to October 8, 2026",
      "Total credits -$5,155.00",
      "Total charges $351.78"
    ].join("\n")
    StatementRead::PdfTextLayer.stubs(:for).returns(
      StatementRead::PdfTextLayer::Result.new(text: totals_only, font_count: 1, usable: true)
    )
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(STATEMENT))

    assert_no_difference -> { PdfImport.count } do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    @link.reload
    assert_equal "queued", @link.status
    assert_match(/nothing imported/i, @link.failure_message)
    validations = @link.extraction.validations
    assert_equal false, validations["statement_totals_reconcile"]
    assert_equal 0, validations["statement_row_count"]
    # R-W8B10 / must-fix 3: a read with NO rows asserts nothing about their
    # dates. Storing `missing_date_rows.empty?` here would be vacuously `true`
    # and the panel would show a GREEN "no statement row is missing its date"
    # beside the red row count. The key must be absent (nil), matching the
    # wave-6 sibling `statement_rows_have_dates`.
    assert_nil validations["statement_rows_missing_dates"],
               "a zero-row read must not assert a date property it never checked"
  end

  test "a scan's drift no longer holds: the text-layer verdict is kept and the model's rows route (W8-E)" do
    # The text layer is USABLE but prints no parseable total, so the text rung is
    # `:unreconcilable` — a fall-back verdict. The geometry rung reads the misread
    # boxes and DRIFTS. Under W8-E (owner-directed) only a TEXT-LAYER drift HOLDS;
    # a scanned statement's drift falls back, so the model's rows route rather than
    # stranding the document. Before W8-E this geometry `:drift` HELD and nothing
    # routed. The caller keeps the text layer's own verdict as the fallback.
    stage_pdf(@link, "synthetic_statement.pdf")
    no_totals = [
      "For the period: September 9, 2026 to October 8, 2026",
      "Purchases",
      "   Sep 08            Sep 09        MERCHANT ONE                                                     10.00"
    ].join("\n")
    StatementRead::PdfTextLayer.stubs(:for).returns(
      StatementRead::PdfTextLayer::Result.new(text: no_totals, font_count: 1, usable: true)
    )
    stub_ocr_success(pages: misread_box_pages)
    stub_provider(FakeProvider.new(STATEMENT))

    # One model batch over all pages, so the model's two rows route exactly
    # (PAGE_BATCH=1 would call the model once per page and merge three copies).
    with_batch_size(3) do
      assert_difference -> { PdfImport.count }, 1 do
        DocumentUnderstandingJob.perform_now(@link.id)
      end
    end

    @link.reload
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 2, import.rows_count, "the model's rows route — a scan's drift does not hold"
    assert_not_includes import.rows.pluck(:name), "MERCHANT ONE",
                        "the text-layer row is not the routed one"
    detail = @link.extraction.validations["statement_read"]
    assert_equal "unreconcilable", detail["verdict"], "the text layer's own fall-back verdict is kept"
    assert_equal "text_layer", detail["source"], "the winning read's source travels with the read"
  end

  test "a proven statement routes as a statement even when the identity read calls it something else (must-fix 2)" do
    # The reader PROVES the statement (its rows reconcile to the printed totals),
    # but the model's identity-only read returns a NON-statement class. The
    # reader's gate is statement-specific arithmetic, so the proof decides the
    # class for routing: the document routes as a statement with the reader's
    # rows, not archived as `other` with green reader checks and no rows.
    stage_pdf(@link, "synthetic_statement.pdf")
    identity = { "document_class" => "other", "institution_name" => "Chase", "field_confidence" => {} }
    stub_ocr_success(pages: [ { page: 1, text: "ACCOUNT SUMMARY\nCHASE", confidence: 0.96, image: "aGk=" } ])
    stub_provider(FakeProvider.new(identity))

    assert_difference -> { PdfImport.count }, 1 do
      DocumentUnderstandingJob.perform_now(@link.id)
    end

    @link.reload
    assert_equal "statement", @link.source, "the reader's proof decides the class for routing"
    assert_equal "reader", @link.classified_by, "the class records that it came from the proof"
    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 9, import.rows_count, "the reader's proven rows route"

    # R-W8B17: the model's own identity read stays visible on `raw_response`.
    assert_equal "other", @link.extraction.raw_response["document_class"]
  end

  test "a statement whose rows drift only through the model falls back, not holds" do
    # The fence's line_items fallback: a dateless model row fails the reader's
    # C1 (a hard date fail). Holding here would strand a document that imports
    # fine today, so a `:drift` from the VISION rung falls back to today's path
    # (scoping R-W8B19); the reader's verdict is recorded, never painted as a
    # routing failure on the panel.
    stub_ocr_success(pages: [ { page: 1, text: "ANTHROPIC -16.52", confidence: 0.96, image: "aGk=" } ])
    misfiled = STATEMENT.merge(
      "transactions" => [],
      "line_items" => [ { "description" => "ANTHROPIC SAN FRANCISCOC A", "amount" => "-16.52" } ]
    )
    stub_provider(FakeProvider.new(misfiled))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal 1, import.rows_count, "the model's rows still route"
    validations = @link.extraction.validations
    assert_equal "drift", validations.dig("statement_read", "verdict")
    assert_equal "vision", validations.dig("statement_read", "source")
    assert_nil validations["statement_totals_reconcile"],
               "a fall-back read must not paint a routing check red on a working document"
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

  # --- Wave 6: one page per call, and the statement's date context -------------

  test "the default read sends one page per provider call so a dense page is never truncated" do
    # A real 6-page Triangle statement read with PAGE_BATCH 4 came back with 7
    # rows where a single page carried 28: a multi-page batch is answered at a
    # summary level, and raising the response-token cap changed nothing. The
    # default must therefore be one page per call, so a page's whole table is
    # enumerable (the deliberate cost: a 40-page statement is 40 calls).
    pages = (1..4).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    seen_batches = []
    provider = FakeProvider.new(STATEMENT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: ""|
      seen_batches << pages.size
      @response
    end
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal [ 1, 1, 1, 1 ], seen_batches,
                 "each page is read on its own, so a dense page's rows are never truncated"
  end

  test "the default single-page read names every row's source page" do
    # One page per call is what makes the page anchor exact: the code comment
    # that used to say a multi-page batch must leave the page unknown no longer
    # bites, because every batch now covers exactly one page (spec §8.3).
    pages = (1..2).map { |n| { page: n, text: "ACCOUNT SUMMARY\nPAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    page_one = STATEMENT.merge("transactions" => [ { "date" => "2026-09-03", "amount" => "-1.00", "name" => "P1", "notes" => "" } ])
    page_two = STATEMENT.merge("transactions" => [ { "date" => "2026-09-04", "amount" => "-2.00", "name" => "P2", "notes" => "" } ])
    stub_provider(ScriptedProvider.new(page_one, page_two))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal [ 1, 2 ], import.rows.order(:source_row_number).pluck(:source_page),
                 "one page per call names each row's page exactly, never nil"
  end

  test "a batch after the first is handed the statement's date context" do
    # The per-batch OCR text carries no year, and the statement's period lives
    # on page one — so a later batch is told the period in its prompt, or the
    # model anchors Sept 20 to a year it made up (the live read said 2023 on a
    # 2026 statement). The first page already carries the period, so it is sent
    # as read.
    pages = (1..2).map { |n| { page: n, text: "PAGE #{n}", confidence: 0.95, image: "cGFnZQ==" } }
    stub_ocr_success(pages: pages)

    seen = []
    provider = FakeProvider.new(STATEMENT)
    provider.define_singleton_method(:understand_document) do |pages:, ocr_text:, family: nil, model: ""|
      seen << ocr_text
      @response
    end
    stub_provider(provider)

    DocumentUnderstandingJob.perform_now(@link.id)

    assert_equal "PAGE 1", seen[0], "the opening page carries its own period; nothing is prepended"
    assert_includes seen[1], "2026-09-01",
                    "a later batch is told the statement's period so a yearless date lands in the right year"
    assert_includes seen[1], "PAGE 2", "the page's own text still reaches the model"
  end

  test "a yearless statement row date is resolved against the statement period" do
    pages = [ { page: 1, text: "Sep 20 ANTHROPIC 16.52", confidence: 0.95, image: "aGk=" } ]
    stub_ocr_success(pages: pages)
    stub_provider(FakeProvider.new(STATEMENT.merge(
      "transactions" => [ { "date" => "Sep 20", "amount" => "-16.52", "name" => "ANTHROPIC", "notes" => "" } ]
    )))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal Date.new(2026, 9, 20).strftime(@family.date_format), import.rows.first.date,
                 "a yearless Sep 20 under a 2026 statement becomes 2026"
  end

  test "a yearless row date is anchored to the statement's year, never the current year" do
    # Today's date happens to be 2026, so a 2026 statement cannot distinguish a
    # real anchor from the downstream Date.parse fallback (which fills the
    # CURRENT year). A statement from 2019 does: without the period anchor the
    # yearless Sep 20 would come back as 2026, the wrong year entirely.
    pages = [ { page: 1, text: "Sep 20 ANTHROPIC 16.52", confidence: 0.95, image: "aGk=" } ]
    stub_ocr_success(pages: pages)
    stub_provider(FakeProvider.new(STATEMENT.merge(
      "statement_period" => { "start" => "2019-09-01", "end" => "2019-09-30" },
      "transactions" => [ { "date" => "Sep 20", "amount" => "-16.52", "name" => "ANTHROPIC", "notes" => "" } ]
    )))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal Date.new(2019, 9, 20).strftime(@family.date_format), import.rows.first.date,
                 "the yearless date is anchored to the statement's period, not today's year"
  end

  test "a row date the model anchored to the wrong year is snapped to the statement period" do
    # The live Triangle read returned 2023-09-20 for a line that reads Sep 20 on
    # a 2026 statement: with no year in the batch's OCR text the model fills one
    # in and guessed three years low. The document's own period is the anchor.
    pages = [ { page: 1, text: "Sep 20 ANTHROPIC 16.52", confidence: 0.95, image: "aGk=" } ]
    stub_ocr_success(pages: pages)
    stub_provider(FakeProvider.new(STATEMENT.merge(
      "transactions" => [ { "date" => "2023-09-20", "amount" => "-16.52", "name" => "ANTHROPIC", "notes" => "" } ]
    )))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal Date.new(2026, 9, 20).strftime(@family.date_format), import.rows.first.date,
                 "a wrong year is snapped to the statement's own period"
  end

  test "a year spanning statement resolves a yearless date to the right side of the new year" do
    # A Dec–Jan cycle spans two calendar years; the anchor must pick the year
    # the date actually falls in, not simply the period's start year.
    pages = [ { page: 1, text: "Dec 25 GYM 44.15", confidence: 0.95, image: "aGk=" },
              { page: 2, text: "Jan 05 ANTHROPIC 16.52", confidence: 0.95, image: "aGk=" } ]
    stub_ocr_success(pages: pages)

    statement = STATEMENT.merge(
      "statement_period" => { "start" => "2026-12-20", "end" => "2027-01-19" }
    )
    page_one = statement.merge("transactions" => [ { "date" => "Dec 25", "amount" => "-44.15", "name" => "GYM", "notes" => "" } ])
    page_two = statement.merge("transactions" => [ { "date" => "Jan 05", "amount" => "-16.52", "name" => "ANTHROPIC", "notes" => "" } ])
    stub_provider(ScriptedProvider.new(page_one, page_two))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    dates = import.rows.order(:source_row_number).pluck(:date)
    assert_equal [ Date.new(2026, 12, 25), Date.new(2027, 1, 5) ].map { |d| d.strftime(@family.date_format) }, dates
  end

  test "a statement with no period leaves its row dates untouched" do
    # No period means no anchor: the normaliser must not re-anchor a row to any
    # year. A date the model read in full — here a year in the past — is left
    # exactly as read, never snapped to the current year or any other.
    pages = [ { page: 1, text: "ACCOUNT SUMMARY\n2020-09-20", confidence: 0.95, image: "aGk=" } ]
    stub_ocr_success(pages: pages)
    stub_provider(FakeProvider.new(STATEMENT.merge(
      "statement_period" => nil,
      "transactions" => [ { "date" => "2020-09-20", "amount" => "-1.00", "name" => "X", "notes" => "" } ]
    )))

    DocumentUnderstandingJob.perform_now(@link.id)

    import = PdfImport.find_by!(account_statement_id: statement_for(@link).id)
    assert_equal Date.new(2020, 9, 20).strftime(@family.date_format), import.rows.first.date,
                 "with no period the row date is left as read — never re-anchored"
  end

  test "a receipt read is unaffected by the statement date context" do
    # A receipt has no statement period, so nothing may be re-anchored: its own
    # date field and its line items are the payload and must survive verbatim.
    pages = [ { page: 1, text: "ACME STORE\nSep 20\nTOTAL 12.34", confidence: 0.97, image: "iVBORw0KGgo=" } ]
    stub_ocr_success(pages: pages)
    receipt = RECEIPT.merge(
      "date" => "Sep 20",
      "line_items" => [ { "description" => "Coffee", "amount" => "12.34" } ]
    )
    stub_provider(FakeProvider.new(receipt))

    DocumentUnderstandingJob.perform_now(@link.id)

    draft = ReceiptImport.find_by!(document_link_id: @link.id)
    assert_equal [ "Coffee" ], draft.line_items.map { |item| item["description"] },
                 "the receipt's line items are untouched"
    assert_equal "Sep 20", @link.extraction.verdict["date"],
                 "a receipt with no period is never re-anchored to the statement's year"
  end

  def statement_for(link)
    AccountStatement.find_by(id: link.reload.account_statement_id)
  end

  # Stages a committed PDF as the link's stored bytes — the reader reads the real
  # bytes through poppler — and re-queues the row as a fresh upload would.
  def stage_pdf(link, name)
    path = file_fixture("statements/#{name}")
    link.stage!(io: File.open(path, "rb"), filename: name, content_type: "application/pdf")
    link.update!(status: "queued")
  end

  # The misread geometry boxes as the sidecar returns them: page 1 carries the
  # statement's clean text (so StatedTotals can read the totals the drifted rows
  # fail against), its boxes come with it. Mirrors geometry_test.rb's builder.
  def misread_box_pages
    statement_text = file_fixture("statements/synthetic_statement.txt").read
    loaded = YAML.safe_load(file_fixture("statements/synthetic_statement_boxes_misread.yml").read)
    loaded.map.with_index do |page, index|
      { page: page["page"], text: index.zero? ? statement_text : "",
        confidence: page["confidence"], boxes: page["boxes"] }
    end
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
