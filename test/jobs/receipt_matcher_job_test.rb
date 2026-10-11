require "test_helper"

class ReceiptMatcherJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  def make_link(status:, text:, document_id: 101)
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: status,
      paperless_document_id: document_id, title: "Receipt"
    )
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: text, created: Date.current, id: document_id))
    link
  end

  RECEIPT = "Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00".freeze

  test "promotes an unlinked receipt with a unique candidate to suggested without linking" do
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    link = make_link(status: "unlinked", text: RECEIPT)

    ReceiptMatcherJob.perform_now(@family.id)

    link.reload
    assert_equal "suggested", link.status
    assert_operator link.confidence, :>=, 90
    assert_nil link.entry_id, "a suggestion must never link the entry"
  end

  test "leaves an unmatched receipt unlinked" do
    link = make_link(status: "unlinked", text: "HANDWRITTEN\nno prices")

    ReceiptMatcherJob.perform_now(@family.id)

    link.reload
    assert_equal "unlinked", link.status
    assert_nil link.confidence
  end

  test "is idempotent" do
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    link = make_link(status: "unlinked", text: RECEIPT)

    2.times { ReceiptMatcherJob.perform_now(@family.id) }

    assert_equal "suggested", link.reload.status
  end

  test "never re-suggests a dismissed receipt, even after the document changes" do
    # Dismiss while nothing matches...
    link = make_link(status: "unlinked", text: "HANDWRITTEN\nno prices")
    ReceiptMatcherJob.perform_now(@family.id)
    assert_equal "unlinked", link.reload.status

    link.dismiss!
    link.reload                      # transition! writes via update_all — reload before reading
    assert_equal "dismissed", link.status

    # ...then the document changes to one that WOULD match, and the entry appears.
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: RECEIPT, created: Date.current, id: 101))

    ReceiptMatcherJob.perform_now(@family.id)

    link.reload
    assert_equal "dismissed", link.status
    assert_nil link.confidence
  end

  # (Ruling M3-C2 R5, 2026-10-11 close-out) P-m3-1's per-link rescue: one
  # raising paperless call must not abort the remaining links.
  test "a raising paperless call does not abort the remaining links" do
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    raising = DocumentLink.create!(
      family: @family, source: "receipt", status: "unlinked",
      paperless_document_id: 501, title: "Outage receipt"
    )
    healthy = DocumentLink.create!(
      family: @family, source: "receipt", status: "unlinked",
      paperless_document_id: 502, title: "Healthy receipt"
    )

    # The bare stub answers every other document (including the
    # unlinked_receipt fixture, id 9001); the with-stub raises for 501 only.
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: RECEIPT, created: Date.current, id: 502))
    Paperless::Client.any_instance.stubs(:document).with(501)
      .raises(Paperless::Error.new("paperless unreachable", code: :unreachable))

    ReceiptMatcherJob.perform_now(@family.id)

    assert_equal "unlinked", raising.reload.status, "the raising link is left for the next tick"
    assert_equal "suggested", healthy.reload.status, "one outage must not abort the remaining links"
  end

  # (Ruling M3-C2 R1, 2026-10-11 close-out) the job carries no viewer; even with
  # a Current.user present in-process it must score the family-wide candidate
  # set (viewer: nil), not the ambient user's.
  test "scores family-wide even when a current user is present (viewer: nil, not Current.user)" do
    create_transaction(account: accounts(:connected), date: Date.current, amount: 55, name: "Starbucks Coffee")
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "unlinked",
      paperless_document_id: 503, title: "Connected receipt"
    )
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: RECEIPT, created: Date.current, id: 503))

    # family_member has no AccountShare on :connected; a Current.user-scoped
    # sweep would see no candidate and leave this link unlinked.
    Current.session = users(:family_member).sessions.create!

    ReceiptMatcherJob.perform_now(@family.id)

    assert_equal "suggested", link.reload.status
  ensure
    Current.session = nil
  end

  test "the cron entry fans out one job per family with matchable links" do
    make_link(status: "unlinked", text: RECEIPT)

    assert_enqueued_with(job: ReceiptMatcherJob, args: [ @family.id ]) do
      ReceiptMatcherJob.perform_now
    end
  end

  test "a full run never creates or edits entries or amounts (D8)" do
    existing = create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    receipt_link = make_link(status: "unlinked", text: RECEIPT)
    other_link = make_link(status: "unlinked", text: "HANDWRITTEN\nno prices", document_id: 102)

    before = Entry.order(:id).pluck(:id, :amount, :date, :name, :updated_at)

    # Mocha `any_instance` is last-stub-wins, so make_link's unparseable stub just
    # replaced the RECEIPT one; re-stub RECEIPT immediately before the run so BOTH
    # links take the matching path. (Ruling P-m3-3, 2026-10-10 pre-flight)
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: RECEIPT, created: Date.current, id: 101))

    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      ReceiptMatcherJob.perform_now(@family.id)
    end

    # Both links matched, so the write path ran — and still wrote no entries (D8).
    assert_equal "suggested", receipt_link.reload.status
    assert_equal "suggested", other_link.reload.status

    assert_equal before, Entry.order(:id).pluck(:id, :amount, :date, :name, :updated_at)
    assert_equal "Starbucks Coffee", existing.reload.name
  end
end
