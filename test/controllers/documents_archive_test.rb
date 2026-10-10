require "test_helper"

class DocumentsArchiveTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("archive"))
    @previous_staging = ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"]
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @tmp.to_s
    sign_in users(:family_admin)
  end

  teardown do
    ENV["OHMZBUDGET_PAPERLESS_STAGING_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  test "the archive lists the family's documents with status pills" do
    get documents_path
    assert_response :success
    assert_select "img[src=?]", file_document_path(document_links(:linked_receipt), kind: "thumb")
    assert_match I18n.t("documents.status.linked"), response.body
  end

  test "the archive is readable by guests" do
    sign_in family_guest
    get documents_path
    assert_response :success # read-only view is fine for guests
  end

  test "the archive renders the dropzone controller" do
    get documents_path
    assert_select "[data-controller~='receipt-dropzone']"
    # Ruling 6 (M1): Stimulus binds only via data-action — pin the wiring so a
    # dead dropzone can never pass this test again.
    assert_select "[data-action~='drop->receipt-dropzone#drop']"
  end

  test "a failed document surfaces its failure message on the card" do
    link = document_links(:queued_receipt)
    link.update_columns(status: "failed", failure_message: "no text layer")
    get documents_path
    assert_response :success
    assert_match "no text layer", response.body
  end

  test "a duplicate sha256 warns and never re-adds" do
    file = uploaded_file(filename: "r.png", content_type: "image/png", content: "k")
    post documents_path, params: { document: file, source: "receipt" }
    assert_response :redirect

    dup = uploaded_file(filename: "r2.png", content_type: "image/png", content: "k")
    assert_no_difference "DocumentLink.count" do
      post documents_path, params: { document: dup, source: "receipt" }
    end
    assert_response :conflict
  ensure
    DocumentLink.find_each { |link| DocumentLink::Staging.delete(link.staged_path) }
  end

  test "a blank source falls back to the receipt-vs-statement heuristic" do
    file = uploaded_file(filename: "bank-statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 x")
    post documents_path, params: { document: file } # no source: the dropzone's default

    link = DocumentLink.order(:created_at).last
    assert_equal "statement", link.source
  end
end
