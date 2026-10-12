require "test_helper"

class ReceiptImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @draft = imports(:receipt_understood)
  end

  test "the one-tap override flips receipt and bill" do
    patch receipt_import_path(@draft), params: { receipt_import: { source: "bill" } }

    assert_redirected_to import_path(@draft)
    assert_equal "bill", @draft.document_link.reload.source
  end

  test "an out-of-list source is refused" do
    patch receipt_import_path(@draft), params: { receipt_import: { source: "statement" } }

    assert_equal "receipt", @draft.document_link.reload.source
  end

  test "manual details write the extracted data" do
    draft = imports(:receipt_draft)
    patch receipt_import_path(draft), params: { receipt_import: { total_amount: "9.99", purchase_date: "2026-09-21", payee: "Bodega" } }

    assert draft.reload.understood?
    assert_equal BigDecimal("9.99"), draft.total_amount
  end

  test "a garbage manual total is refused" do
    draft = imports(:receipt_draft)
    patch receipt_import_path(draft), params: { receipt_import: { total_amount: "not money" } }

    assert_redirected_to import_path(draft)
    assert_not draft.reload.understood?
  end

  test "a completed draft is locked" do
    @draft.update!(status: "complete")
    patch receipt_import_path(@draft), params: { receipt_import: { total_amount: "1.00" } }

    assert_response :redirect
    assert_equal BigDecimal("12.00"), @draft.reload.total_amount
  end

  # (D8, Step 5's end-to-end pin) A settled draft's review screen renders and
  # writes nothing: only Import#publish (the reviewed publish) ever creates an
  # entry. The read itself that settles the draft is pinned in
  # document_understanding_job_test; here the draft is seeded settled.
  test "rendering a settled receipt's review screen writes no money" do
    draft = imports(:receipt_draft)
    draft.document_link.record_content!(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))
    draft.update!(understanding_state: "understood")
    assert draft.reload.understood?

    assert_no_difference [ -> { Entry.count }, -> { Transaction.count } ] do
      get import_path(draft)
    end
    assert_response :success
  end

  test "a publishable draft renders the publish affordance and the item table" do
    @draft.generate_rows_from_line_items!
    get import_path(@draft)

    assert_response :success
    assert_select "form[action=?]", publish_import_path(@draft)
    assert_select "table"
  end

  test "a needs_understanding draft renders the manual entry form" do
    draft = imports(:receipt_draft)
    draft.document_link.update!(status: "failed", failure_message: "the read found no total")
    draft.update!(understanding_state: "needs_understanding")
    assert draft.reload.needs_understanding?

    get import_path(draft)

    assert_response :success
    assert_select "input[name='receipt_import[total_amount]']"
    assert_select "input[name='receipt_import[purchase_date]']"
    assert_select "input[name='receipt_import[payee]']"
  end

  # --- (Ruling M7-L3) terminal complete + replay-safe writer ------------------

  # The review screen IS the post-publish redirect target, so a second click
  # used to reach the writer again (publish_later flipped complete -> importing,
  # defeating Import#publish's guard) and re-minted the split children 2 -> 4.
  # After a successful publish the route replay must add zero rows and leave the
  # children at 2.
  test "the publish route replay after a successful publish writes no money" do
    @draft.generate_rows_from_line_items!

    post publish_import_path(@draft)
    ImportJob.perform_now(@draft)
    assert_equal "complete", @draft.reload.status
    parent = @draft.entries.find_by(parent_entry_id: nil)
    assert_equal 2, parent.child_entries.count

    assert_no_difference [ -> { Entry.count }, -> { Transaction.count } ] do
      # A completed draft is terminal: publish_later refuses the replay before
      # it can enqueue anything (the same shape every non-publishable import
      # gets). And even the first publish's redelivered job writes nothing —
      # import! is replay-safe on its own.
      assert_raises(RuntimeError) { post publish_import_path(@draft) }
      ImportJob.perform_now(@draft)
    end

    assert_equal 2, parent.reload.child_entries.count
  end

  # The reviewer's post-commit-failure shape: Import#publish's status write can
  # fail after the money already landed (status failed, data committed), leaving
  # a still-publishable draft whose route replay must not re-mint the children.
  test "a publish route replay with committed data leaves the children at 2" do
    @draft.generate_rows_from_line_items!

    post publish_import_path(@draft)
    ImportJob.perform_now(@draft)
    @draft.update!(status: :failed, error: "sync failed after the data landed")
    parent = @draft.entries.find_by(parent_entry_id: nil)
    assert_equal 2, parent.child_entries.count

    assert_no_difference [ -> { Entry.count }, -> { Transaction.count } ] do
      post publish_import_path(@draft)
      ImportJob.perform_now(@draft)
    end

    assert_equal "complete", @draft.reload.status
    assert_equal 2, parent.reload.child_entries.count
  end

  test "a completed draft renders no publish affordance" do
    @draft.generate_rows_from_line_items!
    post publish_import_path(@draft)
    ImportJob.perform_now(@draft)
    assert_equal "complete", @draft.reload.status

    get import_path(@draft)

    assert_response :success
    assert_select "form[action=?]", publish_import_path(@draft), count: 0
  end
end
