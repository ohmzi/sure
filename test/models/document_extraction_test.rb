require "test_helper"

class DocumentExtractionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @link = DocumentLink.create!(family: @family, source: "other", status: "queued")
  end

  test "record! persists a read and is the latest for its link" do
    first = DocumentExtraction.record!(
      document_link: @link, provider: "openai", model: "deepseek-flash",
      ocr_engine: "paddleocr-3.0", page_count: 2, ocr_text: "TOTAL 12.34",
      verdict: { "document_class" => "receipt" }, status: "succeeded"
    )
    second = DocumentExtraction.record!(
      document_link: @link, provider: "openai", model: "deepseek-flash",
      ocr_engine: "paddleocr-3.0", page_count: 2, ocr_text: "TOTAL 12.34",
      verdict: { "document_class" => "receipt" }, status: "succeeded"
    )

    assert_equal second.id, @link.reload.extraction.id
    assert_equal 2, @link.document_extractions.count
    assert first.persisted?
  end

  test "status is constrained to the three documented values" do
    extraction = DocumentExtraction.new(document_link: @link, status: "maybe")
    assert_not extraction.valid?
    assert_includes extraction.errors[:status], "is not included in the list"
  end

  test "document_links carries the AI classification columns" do
    @link.update!(classified_by: "ai", classification_confidence: 0.93, page_count: 3,
                  ocr_engine: "paddleocr-3.0")
    assert_equal "ai", @link.reload.classified_by
  end
end
