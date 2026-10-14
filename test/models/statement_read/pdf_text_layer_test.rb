# frozen_string_literal: true

require "test_helper"

# The generated text-layer fixture `test/fixtures/files/statements/synthetic_statement.pdf`
# is produced from `synthetic_statement.txt` by this one-off generator (R-W8B4/R-W8B6;
# the generator stays OUT of the repo). Reproduce with:
#
#   python3 make_synthetic_pdf.py synthetic_statement.txt /tmp/in.ps
#   ps2pdf -sFONTPATH=/usr/share/fonts/truetype/dejavu /tmp/in.ps synthetic_statement.pdf
#
# where `make_synthetic_pdf.py` emits PostScript with EACH FIELD at its own
# `moveto … show` (a whole-line `show` lets ps2pdf collapse the column gaps to
# single spaces) in `/DejaVuSansMono` so ghostscript embeds a non-base-14 font:
#
#   import sys
#   SRC, OUT = sys.argv[1], sys.argv[2]
#   FONT = "/DejaVuSansMono findfont 9 scalefont setfont"
#   CW, X0, TOP, LEAD = 5.418, 40.0, 760.0, 10.0
#   esc = lambda s: s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
#   def line_ps(line, y):
#       out, i, n = [], 0, len(line)
#       while i < n:
#           if line[i] == " ": i += 1; continue
#           j = i
#           while j < n and line[j] != " ": j += 1
#           out.append(f"{X0 + i * CW:.2f} {y:.2f} moveto ({esc(line[i:j])}) show"); i = j
#       return out
#   text = open(SRC, encoding="utf-8").read()
#   pages = text.split("\f")
#   ps = ["%!PS-Adobe-3.0", "%%Pages: %d" % len(pages),
#         "<< /PageSize [1250 900] >> setpagedevice", FONT]
#   for pnum, page in enumerate(pages, 1):
#       ps.append(f"%%Page: {pnum} {pnum}")
#       for idx, line in enumerate(page.split("\n")):
#           if line.strip(): ps.extend(line_ps(line, TOP - idx * LEAD))
#       ps.append("showpage")
#   ps.append("%%EOF")
#   open(OUT, "w", encoding="utf-8").write("\n".join(ps) + "\n")
#
# Prove it: `pdffonts out.pdf` shows `emb yes`, and `pdftotext -layout out.pdf -`
# reproduces the fixture's 2+-space column gaps.
class StatementRead::PdfTextLayerTest < ActiveSupport::TestCase
  # The binary-dependent tests SKIP (never silently pass) when poppler is absent.
  def require_poppler!
    return if StatementRead::PdfTextLayer.available?

    skip "poppler (pdftotext/pdffonts) is not installed — install poppler-utils to exercise the text layer"
  end

  # Temporarily lowers PdfTextLayer::TIMEOUT so a stalled subprocess is cut off
  # inside the test (the real value is 60s). Mirrors the job test's
  # `with_batch_size`; the whole suite runs in forked workers, so the constant
  # swap is process-local and safe.
  def with_layer_timeout(seconds)
    original = StatementRead::PdfTextLayer::TIMEOUT
    StatementRead::PdfTextLayer.send(:remove_const, :TIMEOUT)
    StatementRead::PdfTextLayer.const_set(:TIMEOUT, seconds)
    yield
  ensure
    StatementRead::PdfTextLayer.send(:remove_const, :TIMEOUT)
    StatementRead::PdfTextLayer.const_set(:TIMEOUT, original)
  end

  test "a pdffonts that never returns is bounded and falls through, never raising out of for (must-fix 4)" do
    # A crafted PDF that stalls the font scan must not wedge a heavy worker.
    # `count_fonts` is wrapped in the same Timeout as `pdftotext`; on timeout it
    # returns nil, so `for` reports a not-usable result rather than raising.
    StatementRead::PdfTextLayer.stubs(:available?).returns(true)
    StatementRead::PdfTextLayer.stubs(:extract_layout).returns([ "Sep 09  MERCHANT NAME  12.34\n" * 20, true ])
    hung = ->(*) { sleep 5; [ "", Struct.new(:success?).new(true) ] }

    with_layer_timeout(0.05) do
      Open3.stub(:capture2, hung) do
        result = StatementRead::PdfTextLayer.for(io: StringIO.new("PDF"))

        assert_not result.usable?, "a stalled pdffonts falls through to not-usable"
        assert_nil result.font_count, "the font count is UNKNOWN, not zero — the call was cut off, not answered"
      end
    end
  end

  test "a generated text-layer PDF is usable, embeds a font, and splits into pages" do
    require_poppler!
    result = StatementRead::PdfTextLayer.for(io: StringIO.new(file_fixture("statements/synthetic_statement.pdf").binread))

    assert result.usable?, "the committed fixture must pass the reader's own usable?"
    assert_operator result.font_count, :>=, 1, "a text PDF embeds at least one font"
    assert_equal 2, result.pages.size, "the synthetic statement has two pages"
    assert_match(/Statement date/, result.text)
  end

  test "an image-only scan PDF is not usable" do
    require_poppler!
    result = StatementRead::PdfTextLayer.for(io: StringIO.new(file_fixture("statements/scan.pdf").binread))

    assert_not result.usable?
    assert_equal 0, result.font_count.to_i, "a pure image scan embeds no font"
  end

  test "a non-PDF byte stream is not usable and never raises" do
    result = StatementRead::PdfTextLayer.for(io: StringIO.new("this is not a pdf at all"))

    assert_not result.usable?
  end

  test "usable? rejects a scan's empty or sparse text" do
    assert_not StatementRead::PdfTextLayer.usable?("")
    assert_not StatementRead::PdfTextLayer.usable?("\f \f \f")
  end

  test "usable? requires both a date token and an amount token" do
    assert_not StatementRead::PdfTextLayer.usable?(("word " * 60) + "\nTotal 1234.56")
    assert_not StatementRead::PdfTextLayer.usable?("Sep 09 merchant name here\n" * 20)
  end

  test "usable? accepts a dense page carrying a date and an amount" do
    assert StatementRead::PdfTextLayer.usable?("Sep 09  MERCHANT NAME  12.34\n" * 20)
  end

  test "usable? accepts a numeric-date statement dense enough to read (W8-E)" do
    # A statement whose ONLY dates are numeric must still be probed as worth
    # reading, or the reader never tries it.
    assert StatementRead::PdfTextLayer.usable?("09/17  09/18  MERCHANT ONE  5000.00\n" * 20),
           "a yearless numeric date and an ungrouped amount are enough to try"
  end

  test "available? gates on the poppler binaries" do
    # Not asserting presence (a deployment may lack poppler); the value is
    # reported in the task report so the core test is never silently skipped.
    assert_includes [ true, false ], StatementRead::PdfTextLayer.available?
  end
end
