require "test_helper"

class ReconciliationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  def suggested_link
    entry = @account.entries.create!(
      name: "Starbucks Coffee", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "suggested",
      paperless_document_id: 101, title: "Receipt", confidence: 95
    )
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: "Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00", created: Date.current, id: 101))
    [ entry, link ]
  end

  test "the inbox lists a suggested receipt with its candidate" do
    entry, link = suggested_link

    get reconciliations_url

    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(link)}", count: 1
    assert_match(/#{entry.name}/, response.body)
  end

  test "the inbox lists a pending_review receipt" do
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "pending_review",
      paperless_document_id: 102, title: "Ambiguous receipt"
    )
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: "Receipt\n#{Date.current.iso8601}\nTOTAL $55.00", created: Date.current, id: 102))

    get reconciliations_url

    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(link)}", count: 1
  end

  test "links the chosen candidate to the receipt" do
    entry, link = suggested_link

    post link_reconciliation_url(link, entry_id: entry.id)

    assert_redirected_to reconciliations_url
    link.reload
    assert_equal "linked", link.status
    assert_equal entry, link.entry
    assert_equal 95, link.confidence
  end

  test "refuses to link an entry the matcher did not propose" do
    _entry, link = suggested_link
    stranger = @account.entries.create!(
      name: "Unrelated", date: Date.current, amount: 999, currency: "USD", entryable: Transaction.new
    )
    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Other", currency: "USD", balance: 0, accountable: Depository.new
    )
    foreign = other_account.entries.create!(
      name: "Foreign", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )

    post link_reconciliation_url(link, entry_id: stranger.id)
    post link_reconciliation_url(link, entry_id: foreign.id)

    link.reload
    assert_equal "suggested", link.status
    assert_nil link.entry
  end

  test "dismisses a receipt" do
    _entry, link = suggested_link

    post dismiss_reconciliation_url(link)

    assert_equal "dismissed", link.reload.status
  end

  test "a guest cannot act on receipts" do
    entry, link = suggested_link
    sign_in family_guest

    post link_reconciliation_url(link, entry_id: entry.id)

    assert_redirected_to accounts_url
    assert_equal "suggested", link.reload.status
  end

  test "cannot see or act on another family's receipt" do
    _entry, link = suggested_link
    other = DocumentLink.create!(
      family: families(:empty), source: "receipt", status: "suggested",
      paperless_document_id: 999, title: "Other Family Receipt"
    )

    get reconciliations_url
    assert_no_match(/Other Family Receipt/, response.body)

    post dismiss_reconciliation_url(other)
    assert_response :not_found
  end
end
