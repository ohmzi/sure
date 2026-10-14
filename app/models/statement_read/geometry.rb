# frozen_string_literal: true

class StatementRead
  # The OCR-geometry front-end (§2a of the design) — the rung that reads a SCAN
  # or a photograph.
  #
  # A statement the bank generated as a PDF has a text layer, and `PdfTextLayer`
  # reads it. A scan has none, so it used to fall straight to the vision model —
  # the path that returned 1/7/8/9/21/28 rows on the owner's real statement,
  # because enumerating a dense table through a model is the wrong tool. But the
  # OCR sidecar already returns a box per recognised text line (`{text, bbox,
  # confidence}` at 300 DPI), and geometry survives the jumbling that destroys
  # the flat text: the sidecar's `page.text` concatenates a row's cells in an
  # arbitrary order, while the boxes keep the baseline and the columns intact.
  #
  # This rung reads `page.boxes` ONLY, never `page.text`. It groups the boxes
  # into visual lines by their y-bands, self-calibrates the table's columns from
  # the page's own header (no hard-coded pixels — the line tolerance derives from
  # the data's median box height, so any DPI or template works), splits a box the
  # OCR merged across a column boundary, and renders the result as "cells on a
  # baseline": the SAME structure `TableParser` consumes. Both front-ends
  # therefore feed the identical classifier, the sign-by-section rule and the
  # emitted row shape — nothing is re-implemented here.
  #
  # It decides nothing about money. Its rendered text is proven by the same
  # reconciliation gate as everything else, so a scan whose boxes are too poor to
  # balance is HELD, never partially imported.
  class Geometry
    # The header keywords whose presence (>= 2) marks a column-header band.
    HEADER_TOKENS = %w[TRANSACTION POSTING DATE DESCRIPTION AMOUNT].freeze

    # Loose probes over a rendered line, used ONLY to decide its indentation for
    # the shared classifier's continuation rule — never to build a row.
    DATE_PROBE = /\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\b/
    MONEY_PROBE = /\d{1,3}(?:,\d{3})*\.\d{2}/

    # A leading transaction/posting date inside a box the OCR merged with its
    # neighbour ("Sep 14 FakeShop.ca TORONTO ON"), and a trailing money suffix.
    LEADING_DATE = /\A(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+(?=\S)/
    TRAILING_MONEY = /\s+(-?\$?\d{1,3}(?:,\d{3})*\.\d{2})\z/

    # A wrapped description is indented into the description column (lead >= 4)
    # so `TableParser#continuation?` binds it to the row above.
    CONTINUATION_INDENT = "    "

    # Cells on one baseline are joined by >= 2 spaces, reproducing the layout text
    # `TableParser` splits fields on.
    CELL_GAP = "  "

    # `entries` carry the section/card the gate needs; `rows` is the emitted
    # shape. Mirrors `TableParser::Result`, and adds the one thing that makes the
    # rung actually reach the gate: `to_ary`. The ladder's `entries_result` hands
    # `Array(entries)` to `Reconciliation` (statement_read.rb:262), and a bare
    # Data — or any object without `to_ary` — arrives as a ONE-element array, so
    # the gate reads the wrapper instead of the entries and the rung silently
    # does not work. That trap is why this path was dead and untested until now.
    Result = Data.define(:entries, :rows, :missing_date_rows, :rejected_lines, :period_start, :period_end) do
      def to_ary = entries
      def period_known? = !(period_start.nil? && period_end.nil?)
      def row_count = rows.size
    end

    def self.call(ocr_result) = new(ocr_result).call

    def initialize(ocr_result)
      @ocr_result = ocr_result
    end

    # Either a `Result` (boxes were present and rendered), or `:unavailable` — the
    # ladder's marker to fall through. `:unavailable` covers every way this rung
    # declines: no `Ocr::Result` at all, no page carrying boxes, every box below
    # the confidence floor or empty, or a malformed sidecar. None of these may be
    # a crash (§7).
    def call
      pages = ocr_pages
      return :unavailable if pages.empty?

      bands = pages.map { |page| page_bands(page) }
      return :unavailable if bands.flatten(1).empty?

      parsed = TableParser.call(layout_text(bands))
      Result.new(entries: parsed.entries, rows: parsed.rows,
                 missing_date_rows: parsed.missing_date_rows,
                 rejected_lines: parsed.rejected_lines,
                 period_start: parsed.period_start, period_end: parsed.period_end)
    rescue StandardError
      :unavailable
    end

    private
      # Only a real `Ocr::Result` carries pages; the caller may pass anything (a
      # struct with just `text` in a test, nil when there was no OCR), and none of
      # those has boxes to read.
      def ocr_pages = @ocr_result.respond_to?(:pages) ? Array(@ocr_result.pages) : []

      def boxes_of(page) = page.respond_to?(:boxes) ? page.boxes : nil

      # The whole document's rendered layout text: every page's bands, joined by
      # a form-feed so the classifier's per-line page anchor (a row's
      # `source_page`) follows the OCR page. Columns are calibrated ONCE for the
      # document, from the first header band. The statement's period is read from
      # the boxes like everything else — this rung never touches `page.text`.
      def layout_text(bands)
        calibration = calibrate(bands.flatten(1))
        bands.map do |page_bands|
          page_bands.filter_map { |band| render_band(band, calibration) }.join("\n")
        end.join("\f")
      end

      # One page's boxes -> lines (y-bands) -> cells sorted left-to-right.
      def page_bands(page)
        boxes = normalize(boxes_of(page))
        return [] if boxes.empty?

        bands = band(boxes.sort_by { |box| box[:cy] }, line_tolerance(boxes))
        bands.each { |band| band.sort_by! { |box| box[:x0] } }
        bands
      end

      # The sidecar's boxes are STRING-keyed hashes (Ocr::Client#parse passes the
      # JSON through untouched), so a front-end written against `box[:text]` would
      # read nil for every box and silently drop every line. Normalise once, here,
      # accepting either key type. Drops empty-text boxes and any below the
      # confidence floor (a constant on StatementRead, not a magic number).
      def normalize(raw_boxes)
        Array(raw_boxes).filter_map do |raw|
          next unless raw.is_a?(Hash)

          text = (raw["text"] || raw[:text]).to_s
          next if text.strip.empty?
          next if (raw["confidence"] || raw[:confidence]).to_f < StatementRead::CONFIDENCE_FLOOR.to_f

          x0, y0, x1, y1 = bbox_of(raw)
          { text: text, x0: x0, y0: y0, x1: x1, y1: y1, cy: (y0 + y1) / 2.0 }
        end
      end

      def bbox_of(raw)
        values = Array(raw["bbox"] || raw[:bbox]).map(&:to_f)
        [ values[0] || 0.0, values[1] || 0.0, values[2] || 0.0, values[3] || 0.0 ]
      end

      # The line tolerance is DPI-proof: half the median box height, derived from
      # the data rather than a hard-coded pixel constant. A floor keeps a
      # degenerate page (zero-height boxes) from collapsing every line into one.
      def line_tolerance(boxes)
        tolerance = 0.5 * median(boxes.map { |box| box[:y1] - box[:y0] })
        tolerance.positive? ? tolerance : 1.0
      end

      def median(values)
        sorted = values.sort
        return 0.0 if sorted.empty?

        sorted[(sorted.length - 1) / 2]
      end

      # Sweep the boxes in `cy` order, starting a new band whenever the centre
      # jumps by more than the line tolerance. Boxes within one visual line have
      # near-equal centres and merge; a wrapped line and the next row fall on
      # separate bands (the wrapper is re-attached by the classifier's
      # continuation rule, not here).
      def band(sorted, tolerance)
        bands = []
        sorted.each do |box|
          if bands.empty? || (box[:cy] - bands.last.last[:cy]) > tolerance
            bands << [ box ]
          else
            bands.last << box
          end
        end
        bands
      end

      # Columns, self-calibrating per document (no hard-coded pixels). Either the
      # page's own header fixes them, or — a statement that prints no column
      # header — the largest x-gaps between the cells do. `nil` when neither can
      # be found, in which case no box is split and no prose column is dropped and
      # the classifier reads the cells exactly as the OCR left them.
      def calibrate(bands)
        header_calibration(bands) || gap_calibration(bands)
      end

      # The first band carrying >= 2 header keywords — plus the band right after
      # it when the header is the usual two lines — gives the anchors; boundaries
      # are the midpoints between adjacent anchors.
      def header_calibration(bands)
        cells = header_cells(bands)
        return nil if cells.empty?

        anchors = header_anchors(cells).compact
        amount = cells.find { |box| box[:text].upcase.include?("AMOUNT") }
        boundaries = anchors.each_cons(2).map { |left, right| (left + right) / 2.0 }
        return nil if boundaries.empty? && amount.nil?

        { boundaries: boundaries, amount_right: amount && amount[:x1] }
      end

      # The fallback for a headerless statement: split the sorted cell LEFT edges
      # at their largest gaps, so the columns fall out of the data itself. Left
      # edges, not centres — a wide description box must not drag its column's
      # position right. It deliberately fixes no amount column: without a header,
      # a "right of the amount" prose cut would drop real cells, so none is
      # dropped (the classifier already ignores trailing prose on a row). The
      # design's honest caveat stands: the fallback may swap the date columns, and
      # the gate — not this guess — is what is trusted.
      def gap_calibration(bands)
        cells = bands.flatten(1)
        return nil if cells.size < 3

        lefts = cells.map { |box| box[:x0] }.sort
        cuts = lefts.each_cons(2)
                    .map { |left, right| [ right - left, (left + right) / 2.0 ] }
                    .max_by(3) { |gap, _| gap }
                    .select { |gap, _| gap.positive? }
                    .map { |_, cut| cut }.sort
        return nil if cuts.empty?

        { boundaries: cuts, amount_right: nil }
      end

      def header_cells(bands)
        index = bands.index { |band| header_band?(band) }
        return [] unless index

        cells = bands[index].dup
        cells.concat(bands[index + 1]) if header_band?(bands[index + 1])
        cells
      end

      def header_band?(band)
        return false unless band

        words = band.flat_map { |box| box[:text].upcase.scan(/[A-Z]+/) }
        (HEADER_TOKENS & words).size >= 2
      end

      # [transaction-date left, posting-date left, description left, amount left]
      # — the non-nil anchors a header band supplies, in column order.
      def header_anchors(cells)
        date_cells = cells.select { |box| date_anchor?(box) }.sort_by { |box| box[:x0] }
        positions = date_cells.map { |box| box[:x0] }.uniq
        desc = cells.find { |box| box[:text].upcase.include?("DESCRIPTION") }
        amount = cells.find { |box| box[:text].upcase.include?("AMOUNT") }
        [ positions[0], positions[1], desc && desc[:x0], amount && amount[:x0] ]
      end

      def date_anchor?(box)
        text = box[:text].upcase
        text.match?(/\b(?:TRANSACTION|POSTING|DATE)\b/) && !text.include?("DESCRIPTION")
      end

      # Render one band: drop the interleaved right-hand prose column, split any
      # box the OCR merged across a boundary, join the cells with the layout gap,
      # and indent a date-less, amount-less line so the shared classifier reads it
      # as a continuation of the row above.
      def render_band(band, calibration)
        boxes = band.reject { |box| prose?(box, calibration) }
        cells = boxes.flat_map { |box| split_box(box, calibration) }
                     .map { |cell| cell.gsub(/\s+/, " ").strip }
                     .reject(&:empty?)
        return nil if cells.empty?

        text = cells.join(CELL_GAP)
        (text.match?(DATE_PROBE) || text.match?(MONEY_PROBE) ? "" : CONTINUATION_INDENT) + text
      end

      # A box wholly to the right of the amount column's own right edge is the
      # statement's sidebar/FAQ prose, never a table cell (the design drops that
      # column). Only meaningful once a header fixed the amount column.
      def prose?(box, calibration)
        right = calibration && calibration[:amount_right]
        right ? box[:x0] > right : false
      end

      # Split a box that crosses a column boundary: a leading date prefix (the
      # merged posting date) and a trailing money suffix (a merged amount) each
      # become their own cell; the remainder stays the description. A box that
      # merely reaches across a boundary but starts with neither is left whole —
      # a long description is not a merge.
      def split_box(box, calibration)
        marks = calibration ? calibration[:boundaries] : []
        text = box[:text]
        return [ text ] if marks.empty? || !marks.any? { |mark| mark > box[:x0] && mark < box[:x1] }

        parts = []
        remaining = text
        if (match = remaining.match(LEADING_DATE))
          parts << match[0].strip
          remaining = remaining[match[0].length..].to_s
        end
        if (match = remaining.match(TRAILING_MONEY))
          head = remaining[0...match.begin(0)].to_s
          parts << head unless head.strip.empty?
          parts << match[1]
        else
          parts << remaining unless remaining.strip.empty?
        end
        parts.empty? ? [ text ] : parts
      end
  end
end
