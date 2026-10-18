# frozen_string_literal: true

require "open3"

# Any page of a PDF as a cached PNG (the owner, 2026-10-17): a phone shows a
# document's pages inside the app, because handing the PDF to the browser takes
# an installed app somewhere it cannot come back from. The thumbnail's cache,
# staging guard and atomic render, one picture per page, sharper for reading.
class DocumentLink::PageImage < DocumentLink::Thumbnail
  DPI = 144
  MAX_PAGES = 60

  # How many pages there are to show: the count the read recorded, else
  # pdfinfo's, never more than MAX_PAGES. 0 when it is not a readable PDF.
  # pdfinfo runs at most once per document and request, and a successful count
  # is recorded on the row so later requests do not shell out at all (P1.12).
  def self.count(link)
    return 0 unless pdf?(link)

    recorded = link.page_count.to_i
    return [ recorded, MAX_PAGES ].min if recorded.positive?

    source = DocumentLink::Staging.resolve!(link.stored_path) if link.stored_path.present?
    return 0 unless source&.file?

    # Its own key: the text layer memoizes an HTML String for the same document
    # in the same request, and the two must never be read as one another.
    pages = DocumentLink::RequestCache.fetch([ :page_count, link.id, source.to_s, fingerprint(link, source) ]) do
      output, status = Open3.capture2("pdfinfo", source.to_s)
      next 0 unless status.success?

      count = output[/^Pages:\s+(\d+)/, 1].to_i
      link.update_columns(page_count: count) if count.positive?
      count
    end
    [ pages, MAX_PAGES ].min
  rescue ArgumentError, Errno::ENOENT
    0
  end

  def self.fingerprint(link, source)
    link.content_sha256.presence || "#{source.size}-#{source.mtime.to_i}"
  end
  private_class_method :fingerprint

  def initialize(link, page:)
    super(link)
    @page = page.to_i
  end

  def path
    return nil unless @page.between?(1, MAX_PAGES)

    super
  end

  private
    def cache_path(source)
      DocumentLink::Staging.root.join("pages", "#{@link.id}-#{fingerprint(source)}-p#{@page}.png")
    end

    # Older renders of this page only; the document's other pages stay.
    def cache_glob
      DocumentLink::Staging.root.join("pages", "#{@link.id}-*-p#{@page}.png").to_s
    end

    def render_page(source, prefix)
      started = system(RENDERER, "-png", "-r", DPI.to_s, "-f", @page.to_s, "-l", @page.to_s,
                       source.to_s, prefix.to_s, err: File::NULL)
      return nil if started.nil?

      Dir.glob("#{prefix}-*.png").min
    end
end
