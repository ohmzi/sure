require "test_helper"

class DocumentClassifierTest < ActiveSupport::TestCase
  test "a statement with a period and statement language is corroborated" do
    result = DocumentClassifier.call(
      ai_verdict: DocumentUnderstanding.new(
        "document_class" => "statement",
        "statement_period" => { "start" => "2026-09-01", "end" => "2026-09-30" },
        "field_confidence" => {}
      ),
      filename: "chase.pdf", content_type: "application/pdf",
      ocr_text: "ACCOUNT SUMMARY Statement period 09/01 - 09/30 OPENING BALANCE 100.00"
    )

    assert_equal "statement", result.document_class
    assert result.corroborated
    assert_equal "ai", result.classified_by
  end

  test "a receipt claim with no receipt signal and low confidence falls back to other" do
    result = DocumentClassifier.call(
      ai_verdict: DocumentUnderstanding.new(
        "document_class" => "receipt",
        "field_confidence" => { "total" => 0.2 }
      ),
      filename: "scan.pdf", content_type: "application/pdf",
      ocr_text: "The quick brown fox jumps over the lazy dog"
    )

    assert_equal "other", result.document_class
    assert_not result.corroborated
    assert_equal "fallback", result.classified_by
  end

  test "a receipt with a total, a date and receipt language stays a receipt" do
    result = DocumentClassifier.call(
      ai_verdict: DocumentUnderstanding.new(
        "document_class" => "receipt",
        "total" => "12.34",
        "date" => "2026-10-01",
        "field_confidence" => { "total" => 0.98, "date" => 0.97 }
      ),
      filename: "IMG_0421.jpg", content_type: "image/jpeg",
      ocr_text: "ACME STORE\nTHANK YOU FOR YOUR PURCHASE\nTOTAL 12.34"
    )

    assert_equal "receipt", result.document_class
    assert result.corroborated
  end

  test "an out-of-vocabulary AI class is other, never invented" do
    result = DocumentClassifier.call(
      ai_verdict: DocumentUnderstanding.new(
        "document_class" => "invoice",
        "field_confidence" => {}
      ),
      filename: "x.pdf", content_type: "application/pdf", ocr_text: "anything"
    )

    assert_equal "other", result.document_class
    assert_equal "fallback", result.classified_by
  end

  test "a nil verdict is other, never a raise" do
    result = DocumentClassifier.call(ai_verdict: nil, filename: nil, content_type: nil, ocr_text: nil)

    assert_equal "other", result.document_class
    assert_equal "fallback", result.classified_by
  end
end
