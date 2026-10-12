require "test_helper"

class ReceiptImport::UnderstandJobTest < ActiveSupport::TestCase
  # assert_enqueued_with lives in ActiveJob::TestHelper (the repo convention —
  # Task 1's recorded deviation: the plan's fences assume the helper is present).
  include ActiveJob::TestHelper

  setup do
    @draft = imports(:receipt_draft)
    @link = @draft.document_link
  end

  def settle_with(text)
    @link.record_content!(text)
  end

  test "a settled receipt becomes understood with generated item rows" do
    settle_with(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))

    ReceiptImport::UnderstandJob.perform_now(@draft.id)

    @draft.reload
    assert @draft.understood?
    assert_equal BigDecimal("12.00"), @draft.total_amount
    assert_equal Date.new(2026, 9, 14), @draft.purchase_date
    assert_equal 2, @draft.rows_count
    assert_equal %w[Latte Sandwich], @draft.rows.ordered.map(&:name)
  end

  test "understanding a settled receipt never writes money (D8)" do
    settle_with(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))

    assert_no_difference [ -> { Entry.count }, -> { Transaction.count } ] do
      ReceiptImport::UnderstandJob.perform_now(@draft.id)
    end
    assert_nil @link.reload.entry_id
  end

  test "a settled receipt with no labelled total lands in needs_understanding, not a guess" do
    settle_with(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_no_total.txt")))

    ReceiptImport::UnderstandJob.perform_now(@draft.id)

    @draft.reload
    assert @draft.needs_understanding?
    assert_nil @draft.total_amount
    assert @draft.error.present?
  end

  test "a total without a date stays needs_understanding, never understood" do
    # (repaired 2026-10-10, verifier F8) Entry validates date presence, so
    # `understood` must require the date too; Task 7's manual-details path
    # supplies it (this task has no apply_manual_details! yet).
    settle_with("LATTE LANE CAFE\nTOTAL $9.00")

    ReceiptImport::UnderstandJob.perform_now(@draft.id)

    @draft.reload
    assert @draft.needs_understanding?
    assert_equal BigDecimal("9.00"), @draft.total_amount
    assert @draft.error.present?
  end

  test "an unsettled link waits, and the race resolves once the snapshot lands" do
    @link.update!(status: "processing", paperless_task_id: "task-1")

    assert_enqueued_with(job: ReceiptImport::UnderstandJob) do
      ReceiptImport::UnderstandJob.perform_now(@draft.id) # raises WaitingForText -> retried
    end
    assert @draft.reload.awaiting_ocr?

    settle_with("LATTE LANE CAFE\n2026-09-14\nTOTAL $5.00")
    @link.update!(status: "unlinked")
    ReceiptImport::UnderstandJob.perform_now(@draft.id)
    assert @draft.reload.understood?
  end

  test "a failed link lands needs_understanding immediately" do
    @link.update!(status: "failed", failure_message: "paperless rejected the upload")

    ReceiptImport::UnderstandJob.perform_now(@draft.id)
    assert @draft.reload.needs_understanding?
  end

  test "re-running is idempotent and understood is terminal" do
    settle_with(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))
    ReceiptImport::UnderstandJob.perform_now(@draft.id)
    @draft.update_column(:understanding_state, "understood")

    assert_no_difference -> { Import::Row.count } do
      ReceiptImport::UnderstandJob.perform_now(@draft.id)
    end
  end

  # --- M8 Task 9: the live row broadcast (Ruling M8-L1 decision 3) ------------

  test "a settling draft broadcasts the replaced row with the ready affordance" do
    settle_with(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))
    captured = nil
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with do |family, options|
      captured = options
      family == @link.family && options[:target] == "document_link_#{@link.id}" && options[:html].present?
    end

    ReceiptImport::UnderstandJob.perform_now(@draft.id)

    # The row replaces by dom_id on the family stream, and the HTML is the
    # READY row — the archive flips "Reading…" in place.
    assert_equal ActionView::RecordIdentifier.dom_id(@link), captured[:target]
    assert_includes captured[:html], I18n.t("imports.receipt_import.review_details")
    assert_not_includes captured[:html], I18n.t("imports.receipt_import.reading")
  end

  test "a settle that cannot be read also broadcasts — the row must leave Reading…" do
    @link.update!(status: "failed", failure_message: "paperless rejected the upload")
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Turbo::StreamsChannel.expects(:broadcast_replace_to).once

    ReceiptImport::UnderstandJob.perform_now(@draft.id)
  end
end
