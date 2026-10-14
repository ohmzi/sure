# frozen_string_literal: true

require "test_helper"
require "yaml"

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

  # An OCR result whose BOXES come from the misread fixture (one date glyph read
  # as `Sep O8`), so the geometry rung's rows DRIFT, with the statement's clean
  # text injected so StatedTotals can read the totals it drifts against. Mirrors
  # geometry_test.rb's builder; the leading `::` avoids the test class's local
  # `Ocr` struct.
  def drift_ocr_result
    loaded = YAML.safe_load(file_fixture("statements/synthetic_statement_boxes_misread.yml").read)
    ::Ocr::Result.new(engine: "paddle", pages: loaded.map.with_index do |page, index|
      ::Ocr::Result::Page.new(number: page["page"], text: index.zero? ? text : "",
                              confidence: page["confidence"], boxes: page["boxes"], image: nil)
    end)
  end

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

  test "a later rung's drift no longer outranks the text layer and does not hold (W8-E)" do
    # The text layer is USABLE but prints NO parseable total, so the text rung is
    # `:unreconcilable` — a fall-back verdict. The geometry rung reads the misread
    # boxes and DRIFTS. Under W8-E only a TEXT-LAYER drift holds (the job's
    # `statement_holds?`), and the text layer is always evaluated first, so the
    # geometry drift does NOT win: the caller keeps the text layer's own verdict
    # and the job routes the model's rows rather than holding.
    no_totals = [
      "For the period: September 9, 2026 to October 8, 2026",
      "Purchases",
      "   Sep 08            Sep 09        MERCHANT ONE                                                     10.00"
    ].join("\n")
    stub_layer(layer(text: no_totals))

    result = StatementRead.call(link: link, ocr_result: drift_ocr_result)

    assert_equal :unreconcilable, result.verdict, "the text layer's fall-back is kept; a geometry drift no longer holds"
    assert_equal :text_layer, result.source, "the winning read's source travels with the Result"
  end

  # --- W8-E: numeric dates and ungrouped amounts -------------------------------

  # The numeric-date + ungrouped-amount synthetic (`synthetic_statement_numeric.txt`).
  def numeric_text = @numeric_text ||= file_fixture("statements/synthetic_statement_numeric.txt").read

  test "the numeric-date, ungrouped-amount statement reconciles to :trusted, every applicable check passing (W8-E)" do
    stub_layer(layer(text: numeric_text))
    result = StatementRead.call(link: link)

    assert_equal :text_layer, result.source
    assert result.reconciled?
    assert_equal :trusted, result.verdict
    assert_equal 9, result.row_count
    assert_equal BigDecimal("5155.00"), result.figures["credits_sum"][:read]
    assert_equal BigDecimal("350.00"), result.figures["purchases_sum"][:read]
    %w[row_parse credits_sum purchases_sum charges_identity balance_identity card_1111 card_2222 row_sanity].each do |check|
      assert_equal "+", result.checks[check], "#{check} passes"
    end
  end

  test "a numeric-date statement whose printed total disagrees with its rows still drifts (W8-E)" do
    # The widened date anchor must not loosen the gate: the statement's own total
    # is the proof, and a disagreement is still a `:drift`.
    bad = numeric_text.sub(/(Total purchases\s+)350\.00/, '\1999.00')
    stub_layer(layer(text: bad))
    result = StatementRead.call(link: link)

    assert_equal :drift, result.verdict
    assert_not result.reconciled?
    assert_equal "drift", result.checks["purchases_sum"]
  end

  test "an ungrouped-amount statement whose row disagrees with its totals still drifts (W8-E)" do
    bad = numeric_text.sub(/(TEST MART MISSISSAUGA ON\s+)100\.00/, '\1500.00')
    stub_layer(layer(text: bad))
    result = StatementRead.call(link: link)

    assert_equal :drift, result.verdict
    assert_equal "drift", result.checks["purchases_sum"]
    assert_equal "drift", result.checks["card_1111"]
  end
end
