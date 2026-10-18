# frozen_string_literal: true

require "open3"
require "fileutils"

# The PDF's own text layer (`pdftotext -bbox`) for the provenance viewer
# (P1.12). Extracted once per document and request. The raw HTML is also kept
# beside the document's bytes, named for the digest it came from, so a later
# viewer open does not re-run the subprocess. It is derived from the document,
# so it leaves with the bytes (DocumentLink#delete_stored!) — a tombstone must
# not keep a text layer for a document it no longer holds.
#
# Best-effort: a cache that cannot be written is simply not written, and the
# caller still gets the extracted text. Nothing document-specific is logged.
class DocumentLink::TextLayer
  # The bbox HTML for `link`, from the request cache, the stored cache, or a
  # fresh pdftotext run.
  def self.fetch(link, source)
    DocumentLink::RequestCache.fetch([ :text_layer, link.id, source.to_s, fingerprint(link, source) ]) do
      read(link) || extract_and_write(link, source)
    end
  end

  # The cache file's path, or nil when the row carries no digest to name it by.
  # Public so deletion and tests share one name.
  def self.path_for(link)
    return if link.content_sha256.blank?

    DocumentLink::Staging.resolve!("text/#{link.id}-#{link.content_sha256}.html")
  end

  def self.read(link)
    path = path_for(link)
    path.binread if path&.file?
  rescue SystemCallError
    nil
  end

  def self.delete(link)
    return if link.id.blank?

    path = DocumentLink::Staging.root.join("text")
    # `*.html*` also catches the `.partial` files an interrupted write leaves.
    Dir.glob(path.join("#{link.id}-*.html*").to_s).each { |cached| FileUtils.rm_f(cached) }
  end

  def self.extract_and_write(link, source)
    output, status = Open3.capture2("pdftotext", "-bbox", "-l", DocumentLink::PageImage::MAX_PAGES.to_s,
                                    source.to_s, "-")
    return "" unless status.success?

    write(link, output)
    output
  end
  private_class_method :extract_and_write

  def self.write(link, html)
    path = path_for(link)
    return unless path

    path.dirname.mkpath
    partial = "#{path}.#{SecureRandom.hex(4)}.partial"
    File.binwrite(partial, html)
    File.rename(partial, path)
  rescue SystemCallError => e
    FileUtils.rm_f(partial) if partial
    Rails.logger.warn("DocumentLink::TextLayer could not cache text for #{link.id}: #{e.class}")
    nil
  end
  private_class_method :write

  # stage! records the bytes' digest; the size-and-mtime pair is the fallback
  # for rows staged before it did (the same fingerprint the thumbnails use).
  def self.fingerprint(link, source)
    link.content_sha256.presence || "#{source.size}-#{source.mtime.to_i}"
  end
  private_class_method :fingerprint
end
