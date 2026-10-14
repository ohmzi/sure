# frozen_string_literal: true

require "test_helper"

# The entrypoint and its source ladder: text layer -> geometry (W8-C, still
# :unavailable) -> the injected vision callable. `PdfTextLayer` is stubbed so
# the ladder is exercised without poppler or a real PDF.
class StatementRead::StatementReadTest < ActiveSupport::TestCase
  FixtureLink = Struct.new(:bytes, :original_filename) do
    def stored_io
      return nil if bytes.nil?

      yield StringIO.new(bytes)
    end
  end
  Ocr = Struct.new(:text)
  Understanding = Struct.new(:transactions)

  def text = @text ||= file_fixture("statements/synthetic_statement.txt").read

  def layer(usable: true, text: self.text)
    StatementRead::PdfTextLayer::Result.new(text: text, font_count: 1, usable: usable)
  end

  def stub_layer(value) = StatementRead::PdfTextLayer.stubs(:for).returns(value)

  def link(bytes = "PDF") = FixtureLink.new(bytes, "statement.pdf")

  test "the text layer is read, reconciled, and its source is never hard-coded" do
    stub_layer(layer)
    result = StatementRead.call(link: link)

    assert_equal :text_layer, result.source
    assert result.reconciled?
    assert_equal :trusted, result.verdict
    assert_equal 9, result.row_count
  end

  test "no usable source yields an untrusted :unavailable result" do
    result = StatementRead.call(link: FixtureLink.new(nil, "statement.pdf"))

    assert_equal :unavailable, result.verdict
    assert_nil result.source
    assert_not result.reconciled?
    assert_empty result.rows
  end

  test "the injected vision callable is used only when the deterministic read fails" do
    stub_layer(layer(usable: false))
    rows = StatementRead::TableParser.call(text).rows
    vision = -> { Understanding.new(rows) }

    result = StatementRead.call(link: link, ocr_result: Ocr.new(text), vision: vision)

    assert_equal :vision, result.source
    assert result.reconciled?
    assert_equal 9, result.row_count
  end

  test "vision is not called when the text layer already reconciles" do
    stub_layer(layer)
    vision = -> { flunk("vision must not be called for a reconciled text-layer read") }

    assert_equal :text_layer, StatementRead.call(link: link, vision: vision).source
  end

  test "a statement with no parseable period returns its own reason, not a pile of undated rows (R-W8B14)" do
    bare = text.sub(/For the period:[^\n]*\n/, "").sub(/Statement date:[^\n]*\n/, "")
    stub_layer(layer(text: bare))

    result = StatementRead.call(link: link)

    assert_equal :period_unreadable, result.verdict
    assert_equal :text_layer, result.source
    assert_empty result.rows
    assert_empty result.missing_date_rows
  end

  test "a drifting read is returned untrusted with the detail, and its hold message names the check and figures" do
    bad = text.sub(/(TEST MART MISSISSAUGA ON\s+)100\.00/) { "#{Regexp.last_match(1)}500.00" }
    stub_layer(layer(text: bad))

    result = StatementRead.call(link: link)

    assert_equal :drift, result.verdict
    assert_not result.reconciled?
    assert_equal :text_layer, result.source
    assert_equal "drift", result.checks["purchases_sum"]
    assert_match(/purchases read \$750\.00 vs \$350\.00 stated/, result.hold_message)
  end

  test "drift and unreconcilable are distinct verdicts (R-W8B15)" do
    no_totals = [
      "For the period: September 9, 2026 to October 8, 2026",
      "Purchases",
      "   Sep 08            Sep 09        MERCHANT ONE                                                     10.00"
    ].join("\n")
    stub_layer(layer(text: no_totals))

    assert_equal :unreconcilable, StatementRead.call(link: link).verdict
  end
end
