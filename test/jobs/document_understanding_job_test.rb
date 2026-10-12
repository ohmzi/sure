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

  RECEIPT = {
    "document_class" => "receipt", "total" => "12.34", "date" => "2026-10-01",
    "payee" => "Acme Store", "currency" => "USD", "card_last4" => "4242",
    "line_items" => [ { "description" => "Coffee", "amount" => "12.34" } ],
    "field_confidence" => { "total" => 0.98, "date" => 0.97 }
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

  test "validate accepts agreement and checks the line-item sum and the last4 witness" do
    understanding = DocumentUnderstanding.new(RECEIPT)
    validations = DocumentUnderstandingJob.validate(understanding, ocr_text: "TOTAL 12.34\nCARD 4242")

    assert_equal true, validations["totals_agree"]
    assert_equal true, validations["line_items_sum"]
    assert_equal true, validations["last4_in_ocr"]
  end
end
