# frozen_string_literal: true

require "test_helper"
require "yaml"

# The OCR-geometry rung (task W8-C) over a SYNTHETIC boxes fixture (R-W8C1).
#
# WHAT THIS PROVES: the ALGORITHM — y-banding the boxes into visual lines,
# self-calibrated columns, the split of a box the OCR merged across a column
# boundary, and the SAME downstream classifier as the text-layer path — against
# geometry WE authored by laying `synthetic_statement.txt` into 300-DPI boxes.
#
# WHAT IT DOES NOT PROVE: anything about a real scan. The fixture is clean and
# laid out by us; PaddleOCR on a real photograph merges boxes differently, drops
# glyphs and misreads characters, and the only guarantee there is the shared
# reconciliation gate (§7 of the design) — a scan whose boxes cannot balance is
# HELD, never partially imported. The committed fixture is
# `synthetic_statement_boxes.yml`; `synthetic_statement_boxes_misread.yml` is the
# same layout with one date glyph misread, so the gate's behaviour on OCR error is
# shown rather than hidden.
class StatementRead::GeometryTest < ActiveSupport::TestCase
  FixtureLink = Struct.new(:bytes, :original_filename) do
    def stored_io
      return nil if bytes.nil?

      yield StringIO.new(bytes)
    end
  end

  def synthetic_text = @synthetic_text ||= file_fixture("statements/synthetic_statement.txt").read

  # The sidecar returns each page's flat `text` AND its boxes. The fixture stores
  # boxes only (page text empty) so the rung cannot cheat by reading the very
  # thing it exists to avoid; the flat text is injected only for the ladder's own
  # gate (StatedTotals reads the statement's text, not the boxes).
  def ocr_result(fixture: "synthetic_statement_boxes.yml", text: synthetic_text, pages: nil)
    loaded = pages || YAML.safe_load(file_fixture("statements/#{fixture}").read)
    Ocr::Result.new(engine: "paddle", pages: loaded.map.with_index do |page, index|
      Ocr::Result::Page.new(number: page["page"], text: index.zero? ? text : "",
                            confidence: page["confidence"], boxes: page["boxes"], image: nil)
    end)
  end

  def geometry = @geometry ||= StatementRead::Geometry.call(ocr_result)
  def text_parser = @text_parser ||= StatementRead::TableParser.call(synthetic_text)

  def entries_for(section) = geometry.entries.select { |entry| entry["section"] == section }

  def sum_of(entries) = entries.sum(BigDecimal(0)) { |entry| entry["amount"].to_d.abs }

  test "the geometry read matches the text-layer read for the same statement" do
    assert_equal text_parser.row_count, geometry.row_count,
                 "a scan's boxes reconstruct the same rows the text layer gives"
    %i[payments returns purchases cash fees interest].each do |section|
      text_sum = sum_of(text_parser.entries.select { |entry| entry["section"] == section })
      assert_equal text_sum, sum_of(entries_for(section)), "#{section} bucket matches the text-layer path"
    end
  end

  test "per-card subtotals are carried and reconcile to the statement's own figures" do
    card_1111 = entries_for(:purchases).select { |entry| entry["card"] == "1111" }
    card_2222 = entries_for(:purchases).select { |entry| entry["card"] == "2222" }

    assert_equal 2, card_1111.size
    assert_equal BigDecimal("300.00"), sum_of(card_1111)
    assert_equal 1, card_2222.size
    assert_equal BigDecimal("50.00"), sum_of(card_2222)
  end

  test "a box the OCR merged across a column boundary is split into its date and description" do
    returns = entries_for(:returns)

    assert_equal [ "FakeShop.ca TORONTO ON", "TEST Mktp CA TORONTO ON" ], returns.map { |entry| entry["name"] },
                 "the merged 'Sep 14 FakeShop.ca TORONTO ON' box is split at the boundary"
    assert_equal [ "2026-09-12", "2026-09-12" ], returns.map { |entry| entry["date"] }
  end

  test "a wrapped description and an FX detail bind to the row above, never a new row" do
    row = entries_for(:purchases).find { |entry| entry["name"].start_with?("TEST MART") }

    assert_equal "TEST MART MISSISSAUGA ON HILLPA", row["name"], "the wrapped description rejoins its merchant"
    assert_equal "12.00 USD @ 1.234567890", row["notes"], "the FX detail becomes the row's note"
  end

  test "the interleaved right-hand prose column is dropped, not folded into a name" do
    payment = entries_for(:payments).find { |entry| entry["amount"] == "100.00" }

    assert_equal "RB TELEPAYMENTS/TEST DIRECT", payment["name"]
    assert geometry.rows.none? { |r| r["name"].match?(/stolen|Rewards/) },
           "prose to the right of the amount column is never part of a row"
  end

  test "the drill-down decoy, the summary figures and the low-confidence row are never rows" do
    amounts = geometry.entries.map { |entry| entry["amount"].to_d.abs }

    assert_not_includes amounts, BigDecimal("999.99"), "the page-6 drill-down decoy is excluded"
    assert_not_includes amounts, BigDecimal("1196.78"), "the new balance is not a row"
    assert geometry.rows.none? { |row| row["name"].include?("GHOST") },
           "a box below the confidence floor is dropped, not read"
  end

  test "row page anchors follow the OCR page, not a single flat stream" do
    assert_equal [ 2 ], geometry.rows.map { |row| row["source_page"] }.uniq
  end

  test "the rung reads boxes only — a scrambled page text changes nothing" do
    scrambled = ocr_result(text: "1/2/3 totally unrelated jumble with no period and no totals")

    assert_equal 9, StatementRead::Geometry.call(scrambled).row_count,
                 "page.text is never consulted; the period comes from the boxes too"
  end

  test "through the ladder, a scan's boxes reconcile and report the geometry source" do
    result = StatementRead.call(link: FixtureLink.new(nil, "scan.pdf"), ocr_result: ocr_result)

    assert_equal :geometry, result.source, "the geometry rung, activated by the constant, wins for a scan"
    assert result.reconciled?
    assert_equal :trusted, result.verdict
    assert_equal 9, result.row_count
    assert_equal "5155.0", result.figures["credits_sum"][:read].to_s, "the credits reconcile exactly"
  end

  test "a misread glyph is surfaced and the read is not trusted (fail closed)" do
    result = StatementRead.call(
      link: FixtureLink.new(nil, "scan.pdf"),
      ocr_result: ocr_result(fixture: "synthetic_statement_boxes_misread.yml")
    )

    assert_equal :geometry, result.source
    assert_not result.reconciled?
    assert_equal :drift, result.verdict
    assert_equal "drift", result.checks["row_parse"], "the undated row fails the parse witness"
    assert_equal 1, result.missing_date_rows.size
    assert_match(/Sep O8/, result.missing_date_rows.first, "the OCR error is shown, never hidden")
  end

  test "boxes absent yields :unavailable, so the ladder falls through" do
    empty = [ { "page" => 1, "text" => "", "confidence" => 0.9, "boxes" => [] } ]

    assert_equal :unavailable, StatementRead::Geometry.call(ocr_result(pages: empty))
  end

  test "every box below the confidence floor yields :unavailable" do
    below = [ { "page" => 1, "text" => "", "confidence" => 0.9,
                "boxes" => [ { "text" => "Sep 08", "bbox" => [ 140, 200, 400, 234 ], "confidence" => 0.10 } ] } ]

    assert_equal :unavailable, StatementRead::Geometry.call(ocr_result(pages: below))
  end

  test "the largest-gap fallback calibrates columns when the statement prints no header" do
    # No TRANSACTION/POSTING/DATE/DESCRIPTION/AMOUNT band anywhere: the columns
    # must fall out of the cells' own left-edge gaps, and the merged box must
    # still be split.
    headerless = [ { "page" => 1, "text" => "", "confidence" => 0.9, "boxes" => [
      { "text" => "For the period: September 9, 2026 to October 8, 2026",
        "bbox" => [ 620, 100, 1800, 134 ], "confidence" => 0.97 },
      { "text" => "Purchases", "bbox" => [ 140, 200, 360, 234 ], "confidence" => 0.97 },
      { "text" => "Sep 08", "bbox" => [ 140, 260, 300, 294 ], "confidence" => 0.97 },
      { "text" => "Sep 09 MERCHANT NAME", "bbox" => [ 360, 260, 900, 294 ], "confidence" => 0.90 },
      { "text" => "100.00", "bbox" => [ 1930, 260, 2150, 294 ], "confidence" => 0.97 }
    ] } ]

    result = StatementRead::Geometry.call(ocr_result(pages: headerless))

    assert_equal 1, result.row_count
    assert_equal "MERCHANT NAME", result.rows.first["name"], "the fallback split the merged box"
  end

  test "an input with no pages at all yields :unavailable" do
    assert_equal :unavailable, StatementRead::Geometry.call(Struct.new(:text).new("jumbled"))
    assert_equal :unavailable, StatementRead::Geometry.call(nil)
  end
end
