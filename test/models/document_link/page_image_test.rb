require "test_helper"
require "tmpdir"
require "fileutils"

# Every page of a PDF as a picture (the owner, 2026-10-17): a phone shows the
# document's pages inside the app instead of handing the PDF to the browser,
# which leaves the installed app with no way back.
class DocumentLink::PageImageTest < ActiveSupport::TestCase
  TWO_PAGE_PDF = <<~PDF.freeze
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R 4 0 R]/Count 2>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]>>endobj
    4 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 400]>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
  PDF

  PNG_MAGIC = "\x89PNG\r\n\x1a\n".b

  setup do
    @tmp = Pathname.new(Dir.mktmpdir("document-pages"))
    @env = { "SURE_DOCUMENT_STORE_DIR" => @tmp.to_s }
    @link = document_links(:queued_receipt)
  end

  teardown { FileUtils.remove_entry(@tmp) if @tmp.exist? }

  def stage(bytes)
    @link.stage!(io: StringIO.new(bytes), filename: "statement.pdf", content_type: "application/pdf")
    @link.update_columns(page_count: nil)
    @link.reload
  end

  test "renders a later page to its own cached PNG, apart from the thumbnail" do
    with_env_overrides(@env) do
      stage(TWO_PAGE_PDF)

      page_two = DocumentLink::PageImage.new(@link, page: 2).path

      assert_not_nil page_two
      assert_equal PNG_MAGIC, page_two.binread(8).b
      assert_equal @tmp.join("pages").to_s, page_two.dirname.to_s
      assert_not_equal DocumentLink::PageImage.new(@link, page: 1).path, page_two
    end
  end

  test "counts the pages, and a page past the end has no picture" do
    with_env_overrides(@env) do
      stage(TWO_PAGE_PDF)

      assert_equal 2, DocumentLink::PageImage.count(@link)
      assert_nil DocumentLink::PageImage.new(@link, page: 3).path
      assert_nil DocumentLink::PageImage.new(@link, page: 0).path
    end
  end

  # -- pdfinfo runs once, not on every viewer open (P1.12) -------------------

  test "a page count is read once per request and recorded on the document" do
    with_env_overrides(@env) do
      stage(TWO_PAGE_PDF)
      DocumentLink::RequestCache.reset
      status = mock("pdfinfo status")
      status.stubs(:success?).returns(true)
      Open3.expects(:capture2).with("pdfinfo", anything).once.returns([ "Pages:           2\n", status ])

      2.times { assert_equal 2, DocumentLink::PageImage.count(@link) }
      assert_equal 2, @link.reload.page_count
    end
  end
end
