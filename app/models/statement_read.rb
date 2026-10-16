# frozen_string_literal: true

# The deterministic statement reader and its reconciliation gate.
#
# A bank statement read by a model is read badly — the live Triangle read
# returned 1/7/8/9/21/28 rows where a page carried dozens — because enumerating
# a dense table through a model is the wrong tool. But a statement the bank
# generated as a PDF carries its table as selectable text, and the bank printed
# the rows AND the totals it says those rows should add up to. So the reader
# parses the rows from the document's own text layer (`pdftotext -layout`) and
# then PROVES them against the statement's own printed arithmetic before anyone
# may trust them. A read that cannot be balanced is never published.
#
# This class is the ladder and the entrypoint; it holds no money-writing logic
# (the reviewed-publish path still does that) and changes nothing the app does
# today. Its collaborators each own one idea:
#
#   * PdfTextLayer   — is there a real text layer, and what does it say?
#   * TableParser    — the rows, the sign, the dates (from the text layer).
#   * StatedTotals   — the statement's own printed figures.
#   * Reconciliation — C1–C7 and the balance identity: the proof.
#
# Source order: text layer -> OCR geometry -> vision. Detection only decides
# which source to TRY first — the gate always runs, so a garbage embedded layer
# that passes the density probe is still caught. The geometry rung reads a scan's
# OCR boxes (task W8-C, landed); it declines to `:unavailable` only when the OCR
# leaves it no boxes to read. The vision rung is INJECTED by the caller (the job
# owns provider calls), never called from this PORO.
class StatementRead
  # Money is exact to the cent. The band exists for a bank that rounds its own
  # totals; when a non-zero band is used the residual delta is RECORDED on the
  # verdict (`Result#rounding_delta`), never hidden. Maximum 0.01.
  ROUNDING_BAND = BigDecimal("0.00")

  # Below this many non-whitespace characters per page (median), a "text layer"
  # is a scan's sparse residue, not a statement.
  MIN_CHARS_PER_PAGE = 40

  # The geometry front-end drops boxes recognised below this confidence.
  CONFIDENCE_FLOOR = BigDecimal("0.30")

  # A local subprocess on an untrusted upload is bounded.
  TIMEOUT = 60

  # `:drift` and `:unreconcilable` are deliberately distinct (R-W8B15): drift is
  # a check that RAN and failed — the reader contradicts the statement — and a
  # drift from the TEXT LAYER is the only one that HOLDS, so the caller refuses
  # the import; a drift from a scan (geometry/vision) falls back. The verdicts
  # that hold are `:drift` and `:empty_but_expected`, and only from the text layer
  # — the job's `statement_holds?` is the authority for that, and this class keeps
  # no list to fall out of sync with it (the text layer is evaluated first, so its
  # verdict is the fallback whenever a later rung also fails; see `prefer_hold`).
  # unreconcilable is a statement that printed no usable totals, so nothing could
  # be checked and the caller may fall back to today's path. `:period_unreadable`
  # is R-W8B14: a yearless `Sep 08` with no period to take its year from, so no
  # row's date can be built.
  VERDICTS = %i[trusted drift unreconcilable empty_but_expected period_unreadable unavailable].freeze

  # Human labels for the checks a hold message may name, keyed to the check.
  CHECK_LABELS = {
    "row_parse" => "rows",
    "credits_sum" => "credits",
    "purchases_sum" => "purchases",
    "charges_identity" => "charges",
    "balance_identity" => "the balance",
    "row_count" => "the row count",
    "row_sanity" => "the rows"
  }.freeze

  # The order a hold message names a failing check in, when several fail.
  CHECK_PRIORITY = %w[
    row_parse credits_sum purchases_sum charges_identity balance_identity
    row_count row_sanity
  ].freeze

  # What the reader returns. `rows` is exactly the shape `route_statement`
  # consumes (`{date:, name:, amount:, notes:, source_page:}`, dates ISO, sign by
  # section). Everything else is the evidence for the verdict: the statement's
  # own `stated_totals`, the per-check `checks`/`deltas`, the rows it could not
  # date or classify, the winning `source`, and a plain `hold_message`.
  Result = Data.define(
    :rows, :stated_totals, :deltas, :checks, :reconciled, :missing_date_rows,
    :rejected_lines, :source, :verdict, :figures, :rounding_delta, :identity
  ) do
    # The printed identity (StatementRead::Identity) — only a text-layer read
    # has one, so every other builder leaves it nil.
    def initialize(identity: nil, **fields) = super(identity: identity, **fields)

    def reconciled? = reconciled
    def rows? = rows.any?
    def row_count = rows.size

    # ONE plain sentence naming the failing check and its figures (or, when no
    # figure is at fault, the specific reason). Never a constant that names
    # nothing.
    def hold_message
      case verdict
      when :drift then drift_message
      when :empty_but_expected
        "We couldn't read any rows from this statement even though it states a balance — nothing imported."
      when :unreconcilable
        "We couldn't verify this statement: it doesn't print totals we can check the rows against — nothing imported."
      when :period_unreadable
        "We couldn't read this statement's period, so its yearless dates have no year — nothing imported."
      when :unavailable
        "We couldn't read this statement: no usable text layer or other reader was available — nothing imported."
      else
        "We couldn't balance this statement against its own totals, so nothing was imported."
      end
    end

    private
      # The first failing check, named with its figures, e.g. "purchases read
      # $5,201.13 vs $5,229.61 stated". Falls back to the rejected/missing counts
      # when the failure is not a figure mismatch.
      def drift_message
        name = (CHECK_PRIORITY + checks.keys.grep(/\Acard_/)).find { |key| checks[key] == Reconciliation::DRIFT }
        figure = name && figures[name]
        if name && figure
          "We couldn't balance this statement: #{label_for(name)} read " \
            "#{money(figure[:read])} vs #{money(figure[:stated])} stated — nothing imported."
        elsif rejected_lines.any?
          "We couldn't read this statement: #{rejected_lines.size} line(s) after the itemized detail could not be " \
            "parsed, so the read is truncated — nothing imported."
        elsif missing_date_rows.any?
          "We couldn't read every date on this statement: #{missing_date_rows.size} row(s) carried an amount but no " \
            "date — nothing imported."
        else
          "We couldn't balance this statement against its own totals, so nothing was imported."
        end
      end

      def label_for(name)
        return "card #{name.delete_prefix('card_')} purchases" if name.start_with?("card_")

        CHECK_LABELS.fetch(name, "the rows")
      end

      def money(value)
        ActiveSupport::NumberHelper.number_to_currency(value.to_d, unit: "$")
      end
  end

  def self.call(link:, ocr_result: nil, vision: nil)
    new(link: link, ocr_result: ocr_result, vision: vision).call
  end

  def initialize(link:, ocr_result: nil, vision: nil)
    @link = link
    @ocr_result = ocr_result
    @vision = vision
  end

  # The ladder. The first rung whose rows pass the gate wins. A rung that
  # produced rows but failed the gate is never returned silently: it is kept as
  # the fallback so the caller gets the full untrusted detail rather than a bare
  # "it didn't work". When two rungs fail, the text layer's verdict is kept (see
  # `prefer_hold`): under W8-E only a text-layer HOLD governs, and it is always
  # evaluated first, so a later rung can never mask it.
  def call
    fallback = nil

    layer = text_layer
    if layer&.usable?
      read = text_result(layer.text)
      return read if read.reconciled?
      fallback = read
    end

    geometry = geometry_rung
    unless geometry == :unavailable
      read = entries_result(geometry, source: :geometry, text: geometry_text)
      return read if read.reconciled?
      fallback = prefer_hold(fallback, read)
    end

    if @vision
      read = vision_result
      if read
        return read if read.reconciled?
        fallback = prefer_hold(fallback, read)
      end
    end

    fallback || unavailable_result
  end

  private
    # Must-fix 1, as narrowed by W8-E: when two rungs both fail the gate the
    # caller keeps the FIRST failing rung's Result. Only a text-layer read can
    # HOLD (the job's `statement_holds?`), and the text layer is always evaluated
    # first, so a later geometry/vision rung can never outrank it — the
    # HOLD-ranking this method once performed is unreachable and the body reduces
    # to "first failing rung wins". The winning Result travels whole, its `source`
    # with it.
    def prefer_hold(current, candidate)
      current || candidate
    end

    # Rung 1: the stored PDF's own text layer. `link` is a DocumentLink; its
    # `stored_io` yields the bytes (nil when the row has none, so the block is
    # not called and the layer is nil).
    def text_layer
      return nil unless @link.respond_to?(:stored_io)

      layer = nil
      @link.stored_io { |io| layer = PdfTextLayer.for(io: io, filename: link_filename) }
      layer
    end

    def link_filename
      @link.respond_to?(:original_filename) ? @link.original_filename : nil
    end

    def text_result(text)
      # A bank layout that recognises the statement reads it whole.
      if (layout = Layout.detect(text))
        return layout.call(text)
      end

      parser = TableParser.call(text)
      totals = StatedTotals.call(text)
      return period_unreadable_result(parser, totals) unless parser.period_known?

      build_result(parser.entries, parser.rows, totals, text: text, source: :text_layer,
                   missing: parser.missing_date_rows, rejected: parser.rejected_lines)
        .with(identity: Identity.call(text))
    end

    # Rung 2 (task W8-C, landed): the scan front-end reads the OCR boxes. It
    # returns `:unavailable` — the ladder's fall-through marker — only when the
    # OCR left it no boxes to read (or they are all below the confidence floor).
    def geometry_rung
      return :unavailable unless defined?(StatementRead::Geometry)

      StatementRead::Geometry.call(@ocr_result)
    end

    def geometry_text
      @ocr_result.respond_to?(:text) ? @ocr_result.text.to_s : ""
    end

    # Rung 3: the caller's vision callable returns an understanding (or nil).
    # Its rows are the statement's rows only when they pass the SAME gate; the
    # totals come from the OCR text (StatedTotals works on either front-end).
    def vision_result
      understanding = @vision.call
      rows = vision_rows(understanding)
      return nil if rows.empty?

      text = geometry_text
      totals = StatedTotals.call(text)
      # A model reads the statement's own printed signs; the gate (and the
      # import) work in the reader's convention, so orient before judging.
      oriented = SignOrientation.call(rows, totals, text: text)
      entries = oriented.rows.map { |row| entry_from_row(row) }
      read = build_result(entries, oriented.rows, totals, text: text, source: :vision, missing: [], rejected: [])
      # Rows whose signs the totals could not prove are never "reconciled": they
      # balance in either orientation, so balancing proves nothing (review C1).
      return read if oriented.verified || !read.reconciled?

      read.with(reconciled: false, verdict: :unreconcilable)
    end

    # Vision rows are already row-shaped hashes; they carry no section, so the
    # gate's section buckets fall to the printed sign (design §2d's fallback).
    def vision_rows(understanding)
      rows = if understanding.respond_to?(:transactions)
        understanding.transactions
      elsif understanding.is_a?(Array)
        understanding
      elsif understanding.is_a?(Hash)
        understanding["transactions"] || understanding[:transactions] || []
      else
        []
      end
      Array(rows).select { |row| row.is_a?(Hash) }
    end

    def entry_from_row(row)
      amount = row["amount"] || row[:amount]
      {
        "date" => (row["date"] || row[:date]).to_s,
        "name" => (row["name"] || row[:name]).to_s,
        "amount" => amount.nil? ? nil : format("%.2f", BigDecimal(amount.to_s.delete("$").delete(","))),
        "notes" => row["notes"] || row[:notes],
        "source_page" => row["source_page"] || row[:source_page],
        "section" => nil, "card" => nil
      }
    rescue ArgumentError
      { "date" => nil, "name" => row["name"].to_s, "amount" => nil, "notes" => nil,
        "source_page" => nil, "section" => nil, "card" => nil }
    end

    def entries_result(entries, source:, text:)
      totals = StatedTotals.call(text)
      missing = entries.respond_to?(:missing_date_rows) ? entries.missing_date_rows : []
      rejected = entries.respond_to?(:rejected_lines) ? entries.rejected_lines : []
      rows = entries.respond_to?(:rows) ? entries.rows : Array(entries)
      build_result(Array(entries), rows, totals, text: text, source: source,
                   missing: missing, rejected: rejected)
    end

    def build_result(entries, rows, totals, text:, source:, missing:, rejected:)
      recon = Reconciliation.call(entries, totals, text: text,
                                  missing_date_rows: missing, rejected_lines: rejected)
      Result.new(
        rows: rows, stated_totals: totals, deltas: recon.deltas, checks: recon.checks,
        reconciled: recon.trusted?, missing_date_rows: missing, rejected_lines: rejected,
        source: source, verdict: recon.verdict, figures: recon.figures,
        rounding_delta: recon.rounding_delta
      )
    end

    # R-W8B14: with no parseable period, a yearless `Sep 08` has no year, so
    # there is nothing honest to build a date from. Stop early with its own
    # reason rather than turning every row into a "missing date" row.
    def period_unreadable_result(parser, totals)
      Result.new(
        rows: [], stated_totals: totals, deltas: {}, checks: {}, reconciled: false,
        missing_date_rows: [], rejected_lines: parser.rejected_lines,
        source: :text_layer, verdict: :period_unreadable, figures: {}, rounding_delta: BigDecimal(0)
      )
    end

    def unavailable_result
      Result.new(
        rows: [], stated_totals: {}, deltas: {}, checks: {}, reconciled: false,
        missing_date_rows: [], rejected_lines: [], source: nil, verdict: :unavailable,
        figures: {}, rounding_delta: BigDecimal(0)
      )
    end
end
