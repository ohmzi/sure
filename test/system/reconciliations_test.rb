require "application_system_test_case"

class ReconciliationsTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)

    @family = families(:dylan_family)
    @account = accounts(:depository)
    @entry = @account.entries.create!(
      name: "Starbucks Coffee", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )
    @link = DocumentLink.create!(
      family: @family, source: "receipt", status: "unlinked",
      paperless_document_id: 101, title: "Starbucks receipt"
    )

    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: "Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00", created: Date.current, id: 101))
    # The document proxy streams through the browser; keep it from reaching a
    # live paperless. M1's #file yields (chunk, env) to its block, so the stub
    # must yield — a plain .returns never invokes the block and the img would
    # commit an empty stream.
    Paperless::Client.any_instance.stubs(:file)
      .yields("preview-bytes", stub(status: 200, response_headers: { "content-type" => "image/png" }))
  end

  test "a suggested receipt is linked to its transaction from the inbox" do
    ReceiptMatcherJob.perform_now(@family.id)
    assert_equal "suggested", @link.reload.status

    visit reconciliations_path

    within "##{ActionView::RecordIdentifier.dom_id(@link)}" do
      click_on I18n.t("reconciliations.result.link")
    end

    assert_text I18n.t("reconciliations.link.success")
    @link.reload
    assert_equal "linked", @link.status
    assert_equal @entry, @link.entry
  end

  test "a dismissed receipt leaves the inbox and is not re-suggested" do
    ReceiptMatcherJob.perform_now(@family.id)

    visit reconciliations_path

    within "##{ActionView::RecordIdentifier.dom_id(@link)}" do
      click_on I18n.t("reconciliations.result.dismiss")
    end

    assert_text I18n.t("reconciliations.dismiss.success")
    assert_equal "dismissed", @link.reload.status
    assert_no_selector "##{ActionView::RecordIdentifier.dom_id(@link)}"
  end
end
