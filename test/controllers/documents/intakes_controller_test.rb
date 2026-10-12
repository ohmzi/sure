require "test_helper"

class Documents::IntakesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  # RB1: Task 3 creates document_browser/_tile.html.erb and the grid; until then
  # this endpoint appends the EXISTING document_browser/row partial, so the test
  # asserts the Turbo Stream append (target + the row's markup) rather than
  # tile-specific copy.
  test "an upload answers with a row for the grid, not a redirect" do
    post documents_intake_path,
         params: { document: Rack::Test::UploadedFile.new(StringIO.new("PNGDATA"), "image/png",
                                                          original_filename: "shot.png") }

    assert_response :success
    assert_match "turbo-stream", response.body, "the row must appear in place — no page change"
    assert_match 'action="append"', response.body
    assert_match 'target="documents_grid"', response.body
    # The row partial's own markup: the staged title and its status pill (the
    # enqueued read leaves the row in flight, so the pill reads "Processing" —
    # the row's vocabulary for the design's "Reading…").
    assert_match "shot.png", response.body
    assert_match I18n.t("documents.status.processing"), response.body
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
end
