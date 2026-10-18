require "test_helper"

class Documents::IntakesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  # RB1: Task 3 creates document_browser/_tile.html.erb and the grid, so this
  # endpoint now appends the tile (it appended the row as the placeholder).
  # The test asserts the Turbo Stream structurally (target + the tile's own
  # markup), so the swap does not change its shape.
  test "an upload answers with a tile for the grid, not a redirect" do
    post documents_intake_path,
         params: { document: Rack::Test::UploadedFile.new(StringIO.new("PNGDATA"), "image/png",
                                                          original_filename: "shot.png") }

    assert_response :success
    # The turbo-stream response body is binary; force UTF-8 so the tile's
    # "Reading…" (a non-ASCII ellipsis) can be matched.
    body = response.body.force_encoding("UTF-8")
    assert_match "turbo-stream", body, "the tile must appear in place — no page change"
    assert_match 'action="append"', body
    assert_match 'target="documents_grid"', body
    # The tile's own markup: the staged title and its state pill. The enqueued
    # read leaves the row in flight, so the tile reads the design's "Reading…".
    assert_match "shot.png", body
    assert_match I18n.t("document_browser.tile.states.reading"), body
  end

  # Home's Scan uploads from a page with no grid (the owner, 2026-10-18): it
  # asks to hear back, and the answer carries a toast as well as the tile.
  test "an upload from a page with no grid is confirmed with a toast" do
    post documents_intake_path,
         params: { notify: "1", document: Rack::Test::UploadedFile.new(StringIO.new("PNGDATA"), "image/png",
                                                                       original_filename: "shot.png") }

    assert_response :success
    body = response.body.force_encoding("UTF-8")
    assert_match 'target="notification-tray"', body
    assert_match I18n.t("documents.intakes.create.received"), body
  end

  test "a refusal from a page with no grid is a toast too" do
    post documents_intake_path,
         params: { notify: "1", document: Rack::Test::UploadedFile.new(StringIO.new("\x00\x01"), "application/octet-stream",
                                                                       original_filename: "thing.bin") }

    assert_response :unprocessable_content
    assert_match 'target="notification-tray"', response.body
  end

  test "a rejected file says why on the bar" do
    post documents_intake_path,
         params: { document: Rack::Test::UploadedFile.new(StringIO.new("\x00\x01"), "application/octet-stream",
                                                          original_filename: "thing.bin") }

    assert_response :unprocessable_content
    assert_match I18n.t("document_intake.rejected"), response.body
  end

  test "a CSV goes to the import pipeline instead of the reader" do
    post documents_intake_path,
         params: { document: Rack::Test::UploadedFile.new(StringIO.new("a,b\n1,2\n"), "text/csv",
                                                          original_filename: "bank.csv") }

    assert_response :redirect
    assert_match %r{/imports/}, response.location
  end

  test "a CSV lands on a configuration screen whose import carries the bytes" do
    body = "a,b\n1,2\n"
    post documents_intake_path,
         params: { document: Rack::Test::UploadedFile.new(StringIO.new(body), "text/csv",
                                                          original_filename: "bank.csv") }

    assert_response :redirect
    import = Import.order(:created_at).last
    assert_equal body, import.raw_file_str, "the configuration screen needs the file to have columns to map"
    assert_match %r{/imports/#{import.id}/configuration}, response.location
  end

  test "an oversized CSV says why on the bar and creates no import" do
    body = "a,b\n" + ("x,y\n" * ((Import::MAX_CSV_SIZE / 4) + 1))

    assert_no_difference -> { Import.count } do
      post documents_intake_path,
           params: { document: Rack::Test::UploadedFile.new(StringIO.new(body), "text/csv",
                                                            original_filename: "big.csv") }
    end

    assert_response :unprocessable_content
    assert_match I18n.t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte),
                 response.body
  end

  # The owner's rule: a receipt or bill is in the currency chosen at upload; no
  # choice means the family's display currency (applied where it is used).
  def upload_png(currency: nil)
    post documents_intake_path, params: {
      document: Rack::Test::UploadedFile.new(StringIO.new("PNG-#{SecureRandom.hex(4)}"), "image/png", original_filename: "r.png"),
      currency: currency
    }.compact
    DocumentLink.order(:created_at).last
  end

  test "the currency chosen at upload is kept on the document" do
    assert_equal "USD", upload_png(currency: "usd").currency
  end

  test "no currency, or one that is not a real code, keeps none" do
    assert_nil upload_png.currency
    assert_nil upload_png(currency: "XX$").currency
  end

  test "the upload bar offers a currency, preset to the family's" do
    get documents_path

    assert_select "[data-intake-currency] input[type='hidden'][name='currency'][value='#{users(:family_admin).family.currency}'][data-document-dropzone-target='currency']"
  end
end
