require "test_helper"
require "tmpdir"
require "fileutils"

class DocumentLink::ThumbnailTest < ActiveSupport::TestCase
  # A minimal one-page PDF: the smallest thing poppler will rasterize, so the
  # render tests below exercise the real renderer rather than a stub of it.
  MINIMAL_PDF = <<~PDF.freeze
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
  PDF

  PNG_MAGIC = "\x89PNG\r\n\x1a\n".b

  setup do
    @tmp = Pathname.new(Dir.mktmpdir("document-thumbnail"))
    @env = { "SURE_DOCUMENT_STORE_DIR" => @tmp.to_s }
    # queued_receipt is the PDF fixture (content_type application/pdf).
    @link = document_links(:queued_receipt)
  end

  teardown { FileUtils.remove_entry(@tmp) if @tmp.exist? }

  def stage(bytes, content_type: "application/pdf", link: @link)
    link.stage!(io: StringIO.new(bytes), filename: "statement.pdf", content_type: content_type)
    link.reload
  end

  test "renders a PDF's first page to a cached PNG beside the staged bytes" do
    with_env_overrides(@env) do
      stage(MINIMAL_PDF)

      path = DocumentLink::Thumbnail.path_for(@link)

      assert_not_nil path, "a PDF with bytes renders a preview"
      assert path.file?, "the preview is written to disk"
      assert_equal PNG_MAGIC, path.binread(8).b, "the preview is a PNG"
      assert_equal @tmp.join("thumbs").to_s, path.dirname.to_s,
                   "the cache lives under the store root, not in /tmp"
    end
  end

  test "a second request reuses the cache instead of rendering again" do
    with_env_overrides(@env) do
      stage(MINIMAL_PDF)
      first = DocumentLink::Thumbnail.path_for(@link)
      inode = first.stat.ino

      again = DocumentLink::Thumbnail.path_for(@link)

      assert_equal first.to_s, again.to_s
      # A re-render writes a new file and renames it into place, so an unchanged
      # inode is the deterministic proof that the second call did no work (an
      # mtime comparison would pass on a coarse clock even after a re-render).
      assert_equal inode, again.stat.ino, "the cached preview is reused, not re-rendered"
    end
  end

  test "restaged bytes are never previewed through a stale cache" do
    with_env_overrides(@env) do
      stage(MINIMAL_PDF)
      first = DocumentLink::Thumbnail.path_for(@link)

      # A different document restaged over the same row (what stage! does: new
      # bytes at the same path, a new digest): the old preview is now a picture
      # of bytes that are gone.
      new_bytes = MINIMAL_PDF.sub("300 200", "400 200")
      restaged = DocumentLink::Staging.write(io: StringIO.new(new_bytes), id: @link.id)
      @link.update_columns(stored_path: restaged, content_sha256: Digest::SHA256.hexdigest(new_bytes))

      refetched = DocumentLink::Thumbnail.path_for(@link)

      assert_not_equal first.to_s, refetched.to_s, "the cache is keyed by the bytes it rendered"
      assert refetched.file?
      assert_not first.exist?, "the superseded preview is pruned, not left behind"
    end
  end

  test "a row staged before the digest column existed still gets a preview" do
    with_env_overrides(@env) do
      stage(MINIMAL_PDF)
      @link.update_columns(content_sha256: nil)

      path = DocumentLink::Thumbnail.path_for(@link)

      assert_not_nil path
      assert_equal PNG_MAGIC, path.binread(8).b
    end
  end

  test "an image needs no preview: its own bytes are the picture" do
    with_env_overrides(@env) do
      stage("not really a png", content_type: "image/png")

      assert_nil DocumentLink::Thumbnail.path_for(@link)
    end
  end

  test "a link with no staged bytes has no preview" do
    with_env_overrides(@env) do
      assert_nil DocumentLink::Thumbnail.path_for(document_links(:held_bill))
      assert_nil DocumentLink::Thumbnail.path_for(@link)
    end
  end

  test "a missing renderer degrades to no preview instead of raising" do
    with_env_overrides(@env) do
      stage(MINIMAL_PDF)

      # `system` returns nil when the executable cannot be started, which is the
      # "poppler is not installed" case. The archive must still render.
      DocumentLink::Thumbnail.any_instance.stubs(:render_page).returns(nil)

      assert_nil DocumentLink::Thumbnail.path_for(@link)
    end
  end

  test "a PDF the renderer rejects degrades to no preview" do
    with_env_overrides(@env) do
      stage("%PDF-1.4 truncated beyond repair")

      assert_nil DocumentLink::Thumbnail.path_for(@link)
    end
  end

  test "a stored path outside the store root has no preview" do
    with_env_overrides(@env) do
      @link.update_columns(stored_path: "/etc/passwd")

      assert_nil DocumentLink::Thumbnail.path_for(@link)
    end
  end

  test "delete removes the cached preview" do
    with_env_overrides(@env) do
      stage(MINIMAL_PDF)
      path = DocumentLink::Thumbnail.path_for(@link)

      DocumentLink::Thumbnail.delete(@link)

      assert_not path.exist?, "a tombstone keeps no preview of bytes that are gone"
    end
  end
end
