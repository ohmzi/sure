require "test_helper"

class DocumentIntakeTest < ActiveSupport::TestCase
  # assert_enqueued_with lives here; the suite's model tests that use it include
  # it explicitly (worker_ai_health_test.rb is the precedent).
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  def uploaded(bytes, filename:, content_type:)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)
  end

  test "a photo is routed to the native pipeline and the read is enqueued" do
    assert_enqueued_with(job: DocumentUnderstandingJob) do
      result = DocumentIntake.call(family: @family, uploader: @user,
                                   file: uploaded("PNGDATA", filename: "shot.png", content_type: "image/png"))
      assert_equal :document, result.kind
      # A successful enqueue leaves the row in flight ("processing" — the
      # "Reading…" state), not held ("queued"): DocumentLink::Intake#call
      # mark_processing!s then hands back a fresh read.
      assert_equal "processing", result.record.status
    end
  end

  test "an OFX is detected by its body even when the name lies" do
    body = "OFXHEADER:100\nDATA:OFXSGML\n<OFX><BANKMSGSRSV1></OFX>"
    result = DocumentIntake.call(family: @family, uploader: @user,
                                 file: uploaded(body, filename: "export.csv", content_type: "text/csv"))

    assert_equal :ofx, result.kind, "the body wins over the content type"
    assert_instance_of OfxImport, result.record
  end

  test "a bank CSV is detected as a CSV even when the name says PDF" do
    body = "Date,Description,Amount\n2026-10-01,Cafe,-4.50\n"
    result = DocumentIntake.call(family: @family, uploader: @user,
                                 file: uploaded(body, filename: "statement.pdf", content_type: "application/pdf"))

    assert_equal :csv, result.kind
  end

  test "a CSV carries its bytes onto the import so the config screen has data to map" do
    body = "a,b\n1,2\n"
    result = DocumentIntake.call(family: @family, uploader: @user,
                                 file: uploaded(body, filename: "bank.csv", content_type: "text/csv"))

    assert_equal :csv, result.kind
    # Import#uploaded? is raw_file_str.present? — without the bytes the user
    # lands on a configuration screen with no columns and no rows.
    assert_equal body, result.record.raw_file_str
  end

  test "an oversized CSV is refused rather than half-created" do
    body = "a,b\n" + ("x,y\n" * ((Import::MAX_CSV_SIZE / 4) + 1))

    assert_no_difference -> { Import.count } do
      result = DocumentIntake.call(family: @family, uploader: @user,
                                   file: uploaded(body, filename: "big.csv", content_type: "text/csv"))
      assert_equal :rejected, result.kind
      assert_equal I18n.t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte),
                   result.message
    end
  end

  test "a spreadsheet the CSV importer cannot parse is refused, not handed on" do
    assert_no_difference -> { Import.count } do
      result = DocumentIntake.call(
        family: @family, uploader: @user,
        file: uploaded("PK\x03\x04binary", filename: "book.xlsx",
                       content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      )
      assert_equal :rejected, result.kind
      assert_equal I18n.t("imports.create.invalid_file_type"), result.message
    end
  end

  test "an unrecognised binary is rejected with a message and changes nothing" do
    assert_no_difference -> { DocumentLink.count } do
      result = DocumentIntake.call(family: @family, uploader: @user,
                                   file: uploaded("\x00\x01\x02binary", filename: "thing.bin",
                                                  content_type: "application/octet-stream"))
      assert_equal :rejected, result.kind
      assert result.message.present?
    end
  end
end
