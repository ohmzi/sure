require "test_helper"

# A read's OCR result is kept beside the document so a retry with another
# reader does not run OCR (and the GPU) again.
class DocumentLink::OcrCacheTest < ActiveSupport::TestCase
  setup do
    @link = DocumentLink.create!(family: families(:dylan_family), source: "statement", status: "queued")
    @result = Ocr::Result.new(
      engine: "paddleocr",
      pages: [ Ocr::Result::Page.new(number: 1, text: "Total credits $5.00", confidence: 0.9,
                                     boxes: [ { "text" => "Total", "bbox" => [ 1, 2, 3, 4 ] } ], image: "aGk=") ]
    )
  end

  teardown { DocumentLink::OcrCache.delete(@link) }

  test "a written result reads back page for page" do
    DocumentLink::OcrCache.write(@link, @result)
    cached = DocumentLink::OcrCache.read(@link)

    assert_equal "paddleocr", cached.engine
    assert_equal "Total credits $5.00", cached.text
    assert_equal [ "aGk=" ], cached.page_images
    assert_equal [ { "text" => "Total", "bbox" => [ 1, 2, 3, 4 ] } ], cached.pages.first.boxes
  end

  test "nothing cached reads as nil" do
    assert_nil DocumentLink::OcrCache.read(@link)
  end

  # The cache holds page images of the document, so it must not outlive the
  # document's own bytes (a tombstone keeps no picture of what it held).
  test "giving up the document's bytes drops its cached OCR" do
    DocumentLink::OcrCache.write(@link, @result)

    @link.delete_stored!

    assert_nil DocumentLink::OcrCache.read(@link)
  end

  test "delete removes the cached result" do
    DocumentLink::OcrCache.write(@link, @result)
    DocumentLink::OcrCache.delete(@link)

    assert_nil DocumentLink::OcrCache.read(@link)
  end
end
