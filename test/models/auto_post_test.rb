require "test_helper"

class AutoPostTest < ActiveSupport::TestCase
  # Doubles, so the gate's four conditions can be varied one at a time without
  # building a real draft each time. The integration is pinned separately, in
  # test/jobs/auto_post_receipt_job_test.rb, against real rows.
  #
  # (Task 8 repair) The brief's doubles could not vary two of the four
  # conditions as written: `stub_receipt(single:)` passed the flag straight into
  # the `line_items_split?` member, so the default `single: true` produced a
  # draft that WAS split (inverted), and the class condition was unreachable
  # because the link's `classified_by` was hardcoded "ai" while
  # `stub_extraction`'s `classifications:` argument was never read by the gate
  # (which reads `draft.document_link.classified_by`, not the extraction). The
  # doubles now carry each flag to the thing the gate actually reads.
  def stub_receipt(account: true, single: true, classified: true, total: true, date: true)
    link = Struct.new(:classified_by).new(classified ? "ai" : "fallback")
    Struct.new(:account, :total_amount, :purchase_date, :line_items_split?, :document_link).new(
      account ? accounts(:depository) : nil,
      total ? BigDecimal("12.34") : nil,
      date ? Date.new(2026, 10, 3) : nil,
      !single, link
    )
  end

  def stub_extraction(totals_agree: true)
    Struct.new(:validations).new({ "totals_agree" => totals_agree })
  end

  def allowed?(totals_agree: true, account: true, single: true, classified: true, total: true, date: true)
    AutoPost.allowed?(
      draft: stub_receipt(account: account, single: single, classified: classified, total: total, date: date),
      extraction: stub_extraction(totals_agree: totals_agree)
    )
  end

  test "all four conditions met is the only way through" do
    assert allowed?
    assert_not allowed?(totals_agree: false), "the two reads must agree on the total"
    assert_not allowed?(account: false), "an unresolved account can never auto-post"
    assert_not allowed?(single: false), "a split or batch is never auto-posted"
    assert_not allowed?(classified: false), "an uncorroborated class is never auto-posted"
  end

  test "resolved? needs all three: account, total and purchase date" do
    # Each clause is a separate way to be unresolved, so each is pinned on its
    # own — loosening `resolved?` to any one of them must fail a test.
    assert_not allowed?(account: false), "no account, no auto-post"
    assert_not allowed?(total: false), "no total, no auto-post"
    assert_not allowed?(date: false), "no purchase date, no auto-post"
  end

  test "a nil totals_agree (not checkable) is not agreement" do
    assert_not allowed?(totals_agree: nil),
               "nil means the cheap read could not check the total — that is not agreement"
  end
end
