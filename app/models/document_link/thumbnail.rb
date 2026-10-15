# frozen_string_literal: true

require "fileutils"

# A cached PNG of a document's first page (design D3: "you recognise a document
# by its picture"). Only PDFs come through here — an image's own bytes ARE its
# preview, so `DocumentBrowser::Row` points an image tile at the original and
# this returns nil for it.
#
# The page is rasterized on the first request and cached beside the staged
# bytes. Every failure — no renderer installed, a PDF poppler rejects, a path
# outside the store — degrades to nil so the caller falls back to the file-type
# icon: a missing preview must never keep a document out of the archive.
class DocumentLink::Thumbnail
  # Page 1 only, so a forty-page statement costs the same as a one-page
  # receipt; 100 dpi fills a 4:3 tile at retina size without parking a
  # full-size raster in the store.
  DPI = 100
  RENDERER = "pdftoppm"
  PDF = "application/pdf"

  def self.path_for(link) = new(link).path
  def self.delete(link) = new(link).delete

  # True when this document's preview has to be rendered rather than served: a
  # PDF's bytes are not a picture, an image's are.
  def self.pdf?(link) = link.content_type.to_s == PDF

  def initialize(link)
    @link = link
  end

  # The cached PNG's absolute path, rendering it when the cache is cold. nil
  # when this document has no preview to show.
  def path
    source = staged_source
    return unless source

    cache = cache_path(source)
    return cache if cache.file?

    render(source, cache)
  end

  def delete
    Dir.glob(cache_glob).each { |preview| FileUtils.rm_f(preview) }
  end

  private
    # The staged bytes, or nil when this row cannot have a preview: not a PDF,
    # no bytes, or a path that escapes the store (Staging's own guard).
    def staged_source
      return unless self.class.pdf?(@link)
      return if @link.stored_path.blank?

      source = DocumentLink::Staging.resolve!(@link.stored_path)
      source if source.file?
    rescue ArgumentError
      nil
    end

    # The cache is named for the bytes it was rendered from, so "is this
    # preview current?" is answered by the filename alone — no clock, no stat
    # comparison, and restaged bytes land on a different name rather than
    # silently reusing a picture of the old document.
    def cache_path(source)
      DocumentLink::Staging.root.join("thumbs", "#{@link.id}-#{fingerprint(source)}.png")
    end

    def cache_glob
      DocumentLink::Staging.root.join("thumbs", "#{@link.id}-*.png").to_s
    end

    # stage! records the bytes' digest; the size-and-mtime pair is the fallback
    # for rows staged before it did.
    def fingerprint(source)
      @link.content_sha256.presence || "#{source.size}-#{source.mtime.to_i}"
    end

    def render(source, cache)
      cache.dirname.mkpath
      # Rendered in the cache's own directory so the rename below stays on one
      # filesystem — and therefore atomic, so a concurrent reader sees either
      # the old preview or the new one, never a half-written PNG.
      prefix = cache.dirname.join("render-#{@link.id}-#{SecureRandom.hex(4)}")
      begin
        page = render_page(source, prefix)
        return nil unless page

        File.rename(page, cache)
        prune(cache)
        cache
      ensure
        Dir.glob("#{prefix}-*.png").each { |leftover| FileUtils.rm_f(leftover) }
      end
    end

    # Renders page 1 and returns the PNG's path, or nil when the renderer is
    # absent (`system` returns nil for a binary that cannot be started) or ran
    # and rejected the input (a non-zero exit leaves no page behind).
    def render_page(source, prefix)
      started = system(RENDERER, "-png", "-r", DPI.to_s, "-f", "1", "-l", "1",
                       source.to_s, prefix.to_s)
      return nil if started.nil?

      Dir.glob("#{prefix}-*.png").min
    end

    # One preview per document: drop the previous bytes' render.
    def prune(current)
      Dir.glob(cache_glob).each { |preview| FileUtils.rm_f(preview) unless preview == current.to_s }
    end
end
