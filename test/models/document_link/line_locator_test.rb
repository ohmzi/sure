require "test_helper"
require "tmpdir"
require "fileutils"

# Where on its page a statement line sits (the owner, 2026-10-17): a
# transaction opened from its statement shows the page it is on with its line
# marked, not just the statement.
class DocumentLink::LineLocatorTest < ActiveSupport::TestCase
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("document-lines"))
    @env = { "SURE_DOCUMENT_STORE_DIR" => @tmp.to_s }
    @link = document_links(:queued_receipt)
  end

  teardown { FileUtils.remove_entry(@tmp) if @tmp.exist? }

  def stage_statement
    @link.stage!(io: StringIO.new(file_fixture("imports/sample_bank_statement.pdf").binread),
                 filename: "statement.pdf", content_type: "application/pdf")
    @link.reload
  end

  test "finds the line by its amount and the words of its description" do
    with_env_overrides(@env) do
      stage_statement

      mark = DocumentLink::LineLocator.new(@link).locate(name: "Customer Transfer to 254724***228 - WANJUHI NJOROGE", amount: BigDecimal("-3700"))

      assert_equal 1, mark.page
      assert mark.top.between?(1, 99), "top is a percentage of the page, got #{mark.top}"
      assert mark.height.positive?
      assert mark.height < 10, "one line, not a block of the page, got #{mark.height}"
    end
  end

  test "tells two lines with the same time apart by the description" do
    with_env_overrides(@env) do
      stage_statement
      locator = DocumentLink::LineLocator.new(@link)

      charge = locator.locate(name: "Customer Transfer of Funds Charge", amount: BigDecimal("57"))
      transfer = locator.locate(name: "Customer Transfer to 254724***228 - WANJUHI NJOROGE", amount: BigDecimal("3700"))

      assert charge.top < transfer.top
    end
  end

  test "stays on the page it is told, and finds nothing for an amount that is not there" do
    with_env_overrides(@env) do
      stage_statement
      locator = DocumentLink::LineLocator.new(@link)

      assert_nil locator.locate(name: "Customer Transfer to 254724***228", amount: BigDecimal("3700"), page: 2)
      assert_nil locator.locate(name: "Nothing like it", amount: BigDecimal("98765.43"))
    end
  end

  test "a document that is not a PDF has no lines to find" do
    assert_nil DocumentLink::LineLocator.new(document_links(:understood_receipt_link)).locate(name: "x", amount: 1)
  end

  # -- the text layer is extracted once, not once per viewer open (P1.12) -----

  BBOX_HTML = '<html><body><page width="612.000000" height="792.000000">' \
              '<word xMin="10.000000" yMin="10.000000" xMax="80.000000" yMax="20.000000">1,500.00</word>' \
              "</page></body></html>"

  test "the same document in one request runs pdftotext once" do
    with_env_overrides(@env) do
      stage_statement
      DocumentLink::RequestCache.reset
      status = mock("pdftotext status")
      status.stubs(:success?).returns(true)
      Open3.expects(:capture2).once.returns([ BBOX_HTML, status ])

      2.times do
        mark = DocumentLink::LineLocator.new(@link).locate(name: "", amount: BigDecimal("1500"))
        assert_equal 1, mark.page
      end
    end
  end

  test "a repeat request reads the cached text layer instead of shelling out" do
    with_env_overrides(@env) do
      stage_statement
      DocumentLink::RequestCache.reset
      status = mock("pdftotext status")
      status.stubs(:success?).returns(true)
      Open3.expects(:capture2).once.returns([ BBOX_HTML, status ])

      DocumentLink::LineLocator.new(@link).locate(name: "", amount: BigDecimal("1500"))

      DocumentLink::RequestCache.reset # a later request, same document
      mark = DocumentLink::LineLocator.new(@link).locate(name: "", amount: BigDecimal("1500"))
      assert_equal 1, mark.page
    end
  end

  test "the cached text layer leaves with the document's bytes" do
    with_env_overrides(@env) do
      stage_statement
      DocumentLink::RequestCache.reset
      status = mock("pdftotext status")
      status.stubs(:success?).returns(true)
      Open3.expects(:capture2).once.returns([ BBOX_HTML, status ])

      DocumentLink::LineLocator.new(@link).locate(name: "", amount: BigDecimal("1500"))
      cache = DocumentLink::TextLayer.path_for(@link)
      assert cache.file?

      assert @link.soft_delete!
      assert_not cache.file?, "a tombstone must not keep a text layer derived from bytes it no longer holds"
    end
  end
end
