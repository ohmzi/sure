require "test_helper"

class ReconciliationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  def receipt_text = "Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00"

  def suggested_link
    entry = @account.entries.create!(
      name: "Starbucks Coffee", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "suggested",
      extracted_text: receipt_text, title: "Receipt", confidence: 95
    )
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
      extracted_text: receipt_text, title: "Ambiguous receipt"
    )

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

    # Visible but unproposed: "not a match" (Ruling M3-C2 R1c, 2026-10-11 close-out)
    post link_reconciliation_url(link, entry_id: stranger.id)
    assert_equal I18n.t("reconciliations.link.no_candidate"), flash[:alert]

    # Not on an account this user can see: the standard not-authorized refusal
    post link_reconciliation_url(link, entry_id: foreign.id)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]

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
      title: "Other Family Receipt"
    )

    get reconciliations_url
    assert_no_match(/Other Family Receipt/, response.body)

    post dismiss_reconciliation_url(other)
    assert_response :not_found
  end

  # (Ruling M3-C2 R1, 2026-10-11 close-out) the inbox applies the app's
  # account-visibility model (Account.accessible_by) on the whole path: the
  # rendered candidates, the Link POST and the Dismiss POST.
  test "a member without the account share sees no candidate and cannot link" do
    entry = accounts(:connected).entries.create!(
      name: "Starbucks Coffee", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "suggested",
      extracted_text: receipt_text, title: "Receipt", confidence: 95
    )

    sign_in users(:family_member) # no AccountShare on :connected

    get reconciliations_url
    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(link)}", count: 1
    assert_no_match(/Starbucks Coffee/, response.body, "an unshared account's entry must not render")

    post link_reconciliation_url(link, entry_id: entry.id)

    assert_redirected_to reconciliations_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    link.reload
    assert_equal "suggested", link.status
    assert_nil link.entry
  end

  test "a member without the account share cannot dismiss the suggestion" do
    _entry = accounts(:connected).entries.create!(
      name: "Starbucks Coffee", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "suggested",
      extracted_text: receipt_text, title: "Receipt", confidence: 95
    )

    sign_in users(:family_member)

    post dismiss_reconciliation_url(link)

    assert_redirected_to reconciliations_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_equal "suggested", link.reload.status
  end

  test "a stale suggestion with no match left is still dismissable by any member" do
    # Its entry was edited away: nothing matches family-wide either, so the
    # visibility gate must not block clearing it.
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "suggested",
      extracted_text: receipt_text, title: "Stale receipt", confidence: 80
    )

    sign_in users(:family_member)

    post dismiss_reconciliation_url(link)

    assert_redirected_to reconciliations_url
    assert_equal "dismissed", link.reload.status
  end

  test "a member with the account share sees the candidate and can link" do
    entry, link = suggested_link # :depository is shared with :family_member (full_control)

    sign_in users(:family_member)

    get reconciliations_url
    assert_match(/Starbucks Coffee/, response.body)

    post link_reconciliation_url(link, entry_id: entry.id)

    assert_redirected_to reconciliations_url
    link.reload
    assert_equal "linked", link.status
    assert_equal entry, link.entry
  end

  test "an owner sees and links a candidate on an account shared with no one" do
    entry = accounts(:connected).entries.create!(
      name: "Starbucks Coffee", date: Date.current, amount: 55, currency: "USD", entryable: Transaction.new
    )
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "suggested",
      extracted_text: receipt_text, title: "Receipt", confidence: 95
    )

    get reconciliations_url
    assert_match(/Starbucks Coffee/, response.body)

    post link_reconciliation_url(link, entry_id: entry.id)

    assert_redirected_to reconciliations_url
    link.reload
    assert_equal "linked", link.status
    assert_equal entry, link.entry
  end

  # (Ruling M3-C2 R2, 2026-10-11 close-out) the tap actions must check their
  # guarded transitions' return values and refuse honestly (409), never flash
  # success on a row the user already moved.
  test "a refused link transition answers 409, never a success flash" do
    entry, link = suggested_link
    link.dismiss! # the row already moved on
    link.reload

    post link_reconciliation_url(link, entry_id: entry.id)

    assert_response :conflict
    assert_equal "dismissed", link.reload.status
    assert_nil link.entry
  end

  test "a refused dismiss transition answers 409, never a success flash" do
    _entry, link = suggested_link
    link.dismiss!
    link.reload

    post dismiss_reconciliation_url(link)

    assert_response :conflict
    assert_equal "dismissed", link.reload.status
  end

  test "an unknown or malformed id is a 404 and never reaches the actions" do
    _entry, link = suggested_link
    missing = "00000000-0000-0000-0000-000000000000"

    post link_reconciliation_url(missing, entry_id: missing)
    assert_response :not_found

    post dismiss_reconciliation_url(missing)
    assert_response :not_found

    post dismiss_reconciliation_url("not-a-uuid")
    assert_response :not_found

    assert_equal "suggested", link.reload.status
  end
end
