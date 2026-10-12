require "test_helper"

class DocumentLink::IntakeTest < ActiveSupport::TestCase
  # assert_enqueued_with lives in ActiveJob::TestHelper (repo convention — the
  # same include Task 1's enqueue pin uses; see test/models/document_link_test.rb).
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @file = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")
    Paperless.stubs(:tag_id).returns(1)
  end

  test "creates a staged, processing link and enqueues the upload" do
    link = nil
    assert_enqueued_with(job: Paperless::UploadJob) do
      link = DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file)
    end

    assert link.persisted?
    assert_equal "processing", link.status
    assert_equal "receipt", link.source # SourceGuesser: images are receipts
    assert link.stored_path.present?
  end

  test "refuses bytes the family already archived" do
    DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file)
    duplicate = Rack::Test::UploadedFile.new(file_fixture("receipts/receipt.png"), "image/png")

    assert_raises(DocumentLink::Intake::Duplicate) do
      DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: duplicate)
    end
  end

  test "an unknown explicit source is refused" do
    assert_raises(DocumentLink::Intake::InvalidSource) do
      DocumentLink::Intake.call(family: @family, uploader: users(:family_admin), file: @file, source: "invoice")
    end
  end
end
