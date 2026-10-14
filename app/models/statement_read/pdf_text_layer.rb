# frozen_string_literal: true

require "open3"
require "timeout"
require "tmpdir"

class StatementRead
  # The deterministic "is there a real text layer?" front door for a PDF, and
  # the `pdftotext -layout` wrapper the reader parses.
  #
  # A statement the bank generated as a PDF carries selectable text; a scan or a
  # photo carries none. Poppler's `pdftotext -layout` is the extractor: it is
  # already in the image (poppler-utils ships `pdftoppm` for the vision path),
  # needs no gem, and its `-layout` mode preserves the columns a table needs.
  #
  # This class answers two questions and nothing else: what the document's layout
  # text is, and whether that text is dense enough to be a real text layer rather
  # than a scan's empty render. It decides nothing about money — the
  # reconciliation gate does that, and a garbage embedded OCR layer that passes
  # the density probe is caught there, not here.
  class PdfTextLayer
    # Below this many non-whitespace characters per page (the median across
    # pages), the "text layer" is a scan's sparse residue or nothing at all, and
    # the caller falls through to the OCR/vision path unchanged.
    MIN_CHARS_PER_PAGE = StatementRead::MIN_CHARS_PER_PAGE

    # A local subprocess on an untrusted upload must be bounded. Far longer than
    # any real statement render, short enough that a pathological PDF cannot
    # wedge the read.
    TIMEOUT = StatementRead::TIMEOUT

    # The binaries the layer depends on. Both must be present: `pdftotext` reads
    # the text, `pdffonts` corroborates that a font is embedded. A deployment
    # without poppler falls through to geometry (never a crash).
    BINARIES = %w[pdftotext pdffonts].freeze

    # Deliberately loose — the probe only decides whether the reader is WORTH
    # trying (reconciliation is the real gate), so it accepts the common date
    # shapes: "<Mon> <D>", "<D> <Mon>", "13th 10 2025", and "9/9/2026". W8-E
    # adds the yearless numeric form ("9/9"): a statement whose only dates are
    # numeric must still be probed as usable, or the reader never tries it. `%r{}`
    # delimiters so the embedded `/` needs no escaping.
    DATE_TOKEN = %r{
      (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}\b |
      \b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\b |
      \b\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}\b |
      \b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b |
      \b\d{1,2}(?:st|nd|rd|th)\s+\d{1,2}\s+\d{2,4}\b
    }x
    # The amount probe, grouped or ungrouped (W8-E).
    AMOUNT_TOKEN = /\d+(?:,\d{3})*\.\d{2}/

    Result = Data.define(:text, :font_count, :usable) do
      def usable? = usable

      # The text split into pages (poppler inserts a form-feed between pages, the
      # page anchor TableParser keeps per line).
      def pages = text.to_s.split("\f")
    end

    class << self
      # Are the poppler binaries the layer needs actually installed? Checked up
      # front so a missing binary is a clean fall-through, never a crash.
      def available?
        BINARIES.all? { |name| on_path?(name) }
      end

      # Extract the layout text from the stored bytes. Never raises: a missing
      # poppler, an unreadable PDF or a timeout all return a not-usable result so
      # the caller keeps today's OCR/vision behaviour.
      def for(io:, filename: nil)
        bytes = read_bytes(io)
        return Result.new(text: "", font_count: nil, usable: false) if bytes.to_s.empty?
        return Result.new(text: "", font_count: nil, usable: false) unless available?

        Dir.mktmpdir("pdf-text-layer") do |dir|
          path = File.join(dir, "input.pdf")
          File.binwrite(path, bytes)
          text, ok = extract_layout(path)
          fonts = count_fonts(path)
          # `pdffonts` corroborates: a text PDF always embeds at least one font,
          # so a zero-font document (a pure image scan) is rejected even if some
          # stray characters slipped through.
          usable = ok && usable?(text) && fonts.to_i.positive?
          Result.new(text: text, font_count: fonts, usable: usable)
        end
      end

      # The pure detection, over an already-extracted layout text: enough
      # characters per page to be a real text layer, with a date token AND an
      # amount token to be a table statement worth parsing. Public so it is
      # testable without poppler.
      def usable?(text)
        text = text.to_s
        return false unless text.match?(DATE_TOKEN)
        return false unless text.match?(AMOUNT_TOKEN)

        per_page = text.split("\f").map { |page| page.gsub(/\s/, "").length }
        return false if per_page.empty?

        median(per_page) >= MIN_CHARS_PER_PAGE
      end

      def median(values)
        sorted = values.sort
        sorted[(sorted.length - 1) / 2]
      end

      private
        def on_path?(name)
          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
            File.executable?(File.join(dir, name))
          end
        end

        # `pdftotext -layout` via Open3 with an argv array (never a shell string,
        # so a crafted filename has no injection surface), bounded by TIMEOUT.
        # Returns [text, success].
        def extract_layout(path)
          text, status = Timeout.timeout(TIMEOUT) do
            Open3.capture2("pdftotext", "-layout", path, "-", err: File::NULL)
          end
          [ text.to_s, status.success? ]
        rescue StandardError
          # poppler is not installed, the PDF is unreadable, or the render timed
          # out: not usable, never a crash.
          [ "", false ]
        end

        # The number of fonts listed by pdffonts (its header and rule lines
        # dropped), or nil when pdffonts fails. Bounded by the same TIMEOUT as
        # `pdftotext`: a crafted PDF that stalls the font scan must not wedge the
        # worker, and a timeout falls through to not-usable (nil) exactly like an
        # unreadable PDF — it never raises out of `for`.
        def count_fonts(path)
          out, status = Timeout.timeout(TIMEOUT) do
            Open3.capture2("pdffonts", path, err: File::NULL)
          end
          return nil unless status.success?

          out.to_s.lines.drop(2).count { |line| line.strip.present? }
        rescue StandardError
          nil
        end

        # The bytes as read from the stored io, rewound first so a re-read sees
        # them all. Accepts any reader (File, StringIO, Tempfile).
        def read_bytes(io)
          return nil if io.nil?

          io.rewind if io.respond_to?(:rewind)
          io.read
        end
    end
  end
end
