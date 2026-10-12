require "test_helper"
require "tmpdir"
require "fileutils"

# The native store's invisibility guarantee (retargeted from M1's
# paperless-invisibility audit when the paperless bridge was deleted, Task 12):
# nothing the browser renders exposes the server-side byte pointer, a
# DocumentLink holds no Active Storage attachment, and a page still renders when
# a document's stored bytes are unavailable.
class DocumentStoreTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("document-store"))
    @previous = ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"]
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = @tmp.to_s
    @link = document_links(:linked_receipt)
    @link.update_columns(stored_path: @tmp.join(@link.id).to_s)
    File.binwrite(@link.stored_path, "%PDF-1.7")
    sign_in users(:family_admin)
  end

  teardown do
    ENV["OHMZBUDGET_DOCUMENT_STORE_DIR"] = @previous
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  test "no rendered archive page exposes the store path" do
    get documents_path
    assert_no_match(/#{Regexp.escape(@link.stored_path)}/, response.body)
    get account_statements_path
    assert_no_match(/#{Regexp.escape(@link.stored_path)}/, response.body)
    get documents_path(q: { search: "coffee" })
    assert_no_match(/#{Regexp.escape(@link.stored_path)}/, response.body)
    get viewer_document_path(@link)
    assert_no_match(/#{Regexp.escape(@link.stored_path)}/, response.body)
  end

  test "a companion copy is served without leaking the store path" do
    get file_document_path(@link, kind: "preview")
    assert_response :success
    assert_equal "%PDF-1.7", response.body
    assert_no_match(/#{Regexp.escape(@link.stored_path)}/, response.headers.to_s)
  end

  test "a DocumentLink holds no Active Storage attachment; stored_path is the only byte pointer" do
    assert_empty DocumentLink.attachment_reflections
    assert_includes DocumentLink.column_names, "stored_path"
  end

  test "the browser pages and a viewer render when the stored bytes are missing" do
    @link.update_columns(stored_path: @tmp.join("missing").to_s)

    get documents_path
    assert_response :success
    get account_statements_path
    assert_response :success
    get viewer_document_path(@link)
    assert_response :success
  end
end
