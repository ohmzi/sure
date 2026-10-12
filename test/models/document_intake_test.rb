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
