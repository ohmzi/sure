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
end
