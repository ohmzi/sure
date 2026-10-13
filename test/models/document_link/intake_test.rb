require "test_helper"

class DocumentLink::IntakeTest < ActiveSupport::TestCase
  # assert_enqueued_with lives in ActiveJob::TestHelper (repo convention — the
  # same include Task 1's enqueue pin uses; see test/models/document_link_test.rb).
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
  end

  test "creates a staged, processing link and enqueues the native read" do
    link = nil
    assert_enqueued_with(job: DocumentUnderstandingJob) do
      link = DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file)
    end

    assert link.persisted?
    assert_equal "processing", link.status
    assert_equal "receipt", link.source # a blank source defaults to receipt
    assert link.stored_path.present?
  end

  test "refuses bytes the family already archived" do
    DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file)
    duplicate = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_raises(DocumentLink::Intake::Duplicate) do
      DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: duplicate)
    end
  end

  test "bytes whose archive copy was deleted can be re-added, not refused as a duplicate" do
    # Delete a misread scan, then re-add the same one: the tombstone has given
    # up its bytes (and their digest), so it no longer claims them.
    archived = DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file)
    digest = archived.content_sha256
    archived.soft_delete!
    reintroduced = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    reuploaded = DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: reintroduced)

    assert reuploaded.persisted?, "the identical file is archived again rather than refused"
    assert_equal digest, reuploaded.content_sha256, "the re-added bytes are the same bytes"
  ensure
    DocumentLink::Staging.delete(reuploaded&.stored_path)
  end

  test "an unknown explicit source is refused" do
    assert_raises(DocumentLink::Intake::InvalidSource) do
      DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file, source: "invoice")
    end
  end

  # The wizard hands the staged link to the native read explicitly; the default
  # is the same job, so either way one document is read once.
  test "an explicit enqueue: chooses the job" do
    assert_enqueued_with(job: DocumentUnderstandingJob) do
      DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file,
                                enqueue: ->(link) { DocumentUnderstandingJob.perform_later(link.id) })
    end
  end
end
