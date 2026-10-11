require "test_helper"

class ReceiptMatcherTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  # A DocumentLink whose OCR text is stubbed, so the matcher runs without a live
  # paperless. `created` is the paperless document date used when the receipt
  # text carries no parseable date.
  def link_for(text, created: Date.current, document_id: 101)
    link = DocumentLink.create!(
      family: @family, source: "receipt", status: "unlinked",
      paperless_document_id: document_id, title: "Receipt"
    )
    Paperless::Client.any_instance.stubs(:document)
      .returns(stub(content: text, created: created, id: document_id))
    link
  end

  test "a unique exact-amount entry on the same day is suggested and never linked" do
    entry = create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    link = link_for("Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00")
    result = ReceiptMatcher.call(link)

    assert result.suggested?
    assert_equal [ entry ], result.candidates.map(&:entry)
    candidate = result.best
    assert candidate.exact_amount?
    assert_equal 0, candidate.day_distance
    assert_operator candidate.score, :>=, 90
    assert_nil link.entry_id, "a suggestion must never link the entry (D8)"
  end

  test "the better payee match outranks the worse one on the same day and amount" do
    starbucks = create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks Coffee")
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Shell Gas")
    result = ReceiptMatcher.call(link_for("Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00"))

    assert result.suggested?
    assert_equal starbucks, result.best.entry
    assert_operator result.candidates.first.score, :>, result.candidates.last.score
  end

  test "two equidistant candidates are ambiguous and go to pending_review" do
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Blue Bottle")
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Philz Coffee")
    # The receipt names neither payee, so both score the same on date and payee.
    result = ReceiptMatcher.call(link_for("Receipt\n#{Date.current.iso8601}\nTOTAL $55.00"))

    assert result.pending_review?
    assert_equal 2, result.candidates.size
  end

  test "an entry more than three days away is not a candidate" do
    create_transaction(account: @account, date: Date.current - 4, amount: 55, name: "Starbucks")
    result = ReceiptMatcher.call(link_for("Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00"))

    assert result.no_match?
    assert_empty result.candidates
  end

  test "an entry whose amount differs is not a candidate" do
    create_transaction(account: @account, date: Date.current, amount: 55.01, name: "Starbucks")
    result = ReceiptMatcher.call(link_for("Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00"))

    assert result.no_match?
  end

  test "an unparseable document is no_match, never a guess" do
    create_transaction(account: @account, date: Date.current, amount: 55, name: "Starbucks")
    result = ReceiptMatcher.call(link_for("HANDWRITTEN\nno prices"))

    assert result.no_match?
    assert_empty result.candidates
  end

  test "an undated receipt is matched against the paperless document date" do
    # No date in the OCR text, so document_date falls back to the paperless
    # `created` value and the window is anchored there.
    entry = create_transaction(account: @account, date: 1.day.ago.to_date, amount: 55, name: "Starbucks Coffee")
    result = ReceiptMatcher.call(link_for("Starbucks\nTOTAL $55.00", created: 1.day.ago.to_date))

    assert result.suggested?
    assert_equal [ entry ], result.candidates.map(&:entry)
  end

  test "only entries in the account's own currency are candidates" do
    foreign = @account.entries.create!(
      name: "Starbucks", date: Date.current, amount: 55, currency: "EUR", entryable: Transaction.new
    )
    result = ReceiptMatcher.call(link_for("Starbucks\n#{Date.current.iso8601}\nTOTAL $55.00"))

    assert result.no_match?
    assert_not_includes result.candidates.map(&:entry), foreign
  end
end
