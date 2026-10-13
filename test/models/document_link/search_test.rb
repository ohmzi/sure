require "test_helper"

class DocumentLink::SearchTest < ActiveSupport::TestCase
  setup { @family = families(:dylan_family) }

  test "scopes to the family and the requested sources, newest first" do
    search = DocumentLink::Search.new(family: @family, sources: %w[receipt bill])

    ids = search.relation.pluck(:id)
    assert_includes ids, document_links(:unlinked_receipt).id
    assert_includes ids, document_links(:held_bill).id
    assert_equal search.relation.first, DocumentLink::Search.new(family: @family).relation.first
  end

  test "no sources means no source filter" do
    other = document_links(:queued_receipt)
    other.update!(source: "statement")

    assert_includes DocumentLink::Search.new(family: @family).relation.pluck(:id), other.id
    assert_not_includes DocumentLink::Search.new(family: @family, sources: %w[receipt bill]).relation.pluck(:id), other.id
  end

  # -- search, sort and the document-date range (M8 Task 5) --------------------

  test "search applies within the family and source scope" do
    other = document_links(:queued_receipt)
    other.update!(source: "statement", title: "Waterworks invoice")

    scoped = DocumentLink::Search.new(family: @family, sources: %w[receipt bill], filters: { search: "water" })
    assert_not_includes scoped.relation.pluck(:id), other.id

    unscoped = DocumentLink::Search.new(family: @family, filters: { search: "water" })
    assert_includes unscoped.relation.pluck(:id), other.id
  end

  test "an unknown sort falls back to newest" do
    assert_equal DocumentLink::Search.new(family: @family).relation.pluck(:id),
                 DocumentLink::Search.new(family: @family, filters: { sort: "bogus" }).relation.pluck(:id)
  end

  test "document_date sort uses the understood draft's parsed date" do
    imports(:receipt_understood).update!(
      extracted_data: imports(:receipt_understood).extracted_data.merge("date" => 1.day.from_now.to_date.iso8601)
    )

    ordered = DocumentLink::Search.new(family: @family, filters: { sort: "document_date" }).relation.pluck(:id)
    assert_equal document_links(:understood_receipt_link).id, ordered.first
  end

  test "the date range filters on the derived document date and ignores invalid dates" do
    link = document_links(:unlinked_receipt)
    link.receipt_imports.destroy_all
    link.update_columns(created_at: Time.zone.parse("2026-09-15 12:00"))

    in_range = DocumentLink::Search.new(family: @family, filters: { date_from: "2026-09-01", date_to: "2026-09-30" }).relation.pluck(:id)
    assert_includes in_range, link.id

    out_of_range = DocumentLink::Search.new(family: @family, filters: { date_from: "2026-10-01" }).relation.pluck(:id)
    assert_not_includes out_of_range, link.id

    # Invalid dates are ignored (Date.iso8601 rescue nil), never a crash.
    invalid = DocumentLink::Search.new(family: @family, filters: { date_from: "not-a-date" }).relation.pluck(:id)
    assert_includes invalid, link.id
  end

  test "the displayed date is the same coerced date the range and sort use" do
    # (Ruling M8-C3, 2026-10-11 close-out) a needs_understanding draft carrying
    # a purchase date, and a newer draft that is not understood, must not move
    # the row's display away from DOCUMENT_DATE_SQL's precedence.
    link = document_links(:unlinked_receipt)
    link.receipt_imports.destroy_all
    link.update_columns(created_at: Time.zone.parse("2026-09-15 12:00"))

    ReceiptImport.create!(family: @family, document_link: link, type: "ReceiptImport",
                          status: "pending", understanding_state: "needs_understanding",
                          extracted_data: { "date" => "2026-01-05" })

    assert_equal "2026-09-15", document_date_sql(link) # the authority: the upload date
    assert_equal Date.iso8601("2026-09-15"), link.document_date
    assert_equal link.document_date, DocumentBrowser::Row.for_document_link(link).date
    assert_includes document_date_range(link, "2026-09-01", "2026-09-30"), link.id
    assert_not_includes document_date_range(link, "2026-01-01", "2026-01-31"), link.id

    # A NEWER draft that is not understood must not shadow the latest
    # understood one — the SQL reads only understood drafts, so the display
    # follows that same pick.
    ReceiptImport.create!(family: @family, document_link: link, type: "ReceiptImport",
                          status: "pending", understanding_state: "understood",
                          extracted_data: { "date" => "2026-08-01" })

    assert_equal "2026-08-01", document_date_sql(link)
    assert_equal Date.iso8601("2026-08-01"), link.reload.document_date
    assert_equal link.document_date, DocumentBrowser::Row.for_document_link(link).date
  end

  # -- the tag facet (M8 Task 6) ----------------------------------------------

  test "the tag filter matches by array overlap on the stored snapshot" do
    document_links(:unlinked_receipt).update!(tags: %w[ohmzbudget receipt])
    document_links(:held_bill).update!(tags: %w[ohmzbudget bill])

    bill_only = DocumentLink::Search.new(family: @family, filters: { tags: %w[bill] }).relation.pluck(:id)
    assert_includes bill_only, document_links(:held_bill).id
    assert_not_includes bill_only, document_links(:unlinked_receipt).id

    # A blank / empty selection filters nothing (the facet's cleared state).
    unfiltered = DocumentLink::Search.new(family: @family).relation.pluck(:id)
    assert_equal unfiltered, DocumentLink::Search.new(family: @family, filters: { tags: [] }).relation.pluck(:id)
    assert_equal unfiltered, DocumentLink::Search.new(family: @family, filters: { tags: [ "" ] }).relation.pluck(:id)

    # A name no row carries is a real filter: an empty page, never a widened one.
    assert_empty DocumentLink::Search.new(family: @family, filters: { tags: %w[nope] }).relation.pluck(:id)
  end

  # -- the merchant / amount facet (M8 Task 7) ---------------------------------

  test "merchant and amount filter on the understood draft's extracted data" do
    imports(:receipt_understood).update!(
      extracted_data: imports(:receipt_understood).extracted_data.merge("payee" => "Starbucks", "total" => "12.00")
    )
    link = document_links(:understood_receipt_link)

    found = DocumentLink::Search.new(family: @family, filters: { merchant: "starb" }).relation.pluck(:id)
    assert_includes found, link.id

    found = DocumentLink::Search.new(family: @family, filters: { amount_min: "10", amount_max: "15" }).relation.pluck(:id)
    assert_includes found, link.id

    # A max-only bound is reachable from the form (fill one box): the named-bind
    # carrier must tolerate the unbound half (the Task 7 repair pin).
    assert_includes DocumentLink::Search.new(family: @family, filters: { amount_max: "15" }).relation.pluck(:id), link.id

    assert_not_includes DocumentLink::Search.new(family: @family, filters: { amount_min: "20" }).relation.pluck(:id), link.id
    assert_empty DocumentLink::Search.new(family: @family, filters: { merchant: "nobody" }).relation.pluck(:id)
  end

  test "a non-numeric extracted total never matches an amount filter and never raises" do
    imports(:receipt_understood).update!(extracted_data: imports(:receipt_understood).extracted_data.merge("total" => "n/a"))
    assert_empty DocumentLink::Search.new(family: @family, filters: { amount_min: "0" }).relation.pluck(:id)

    # (repair pin 2026-10-11, Task 7) "12x34" is the near-numeric value only a
    # wildcard-dot regex would admit: it must fail the guard (NULL) and never
    # reach ::numeric (PG::InvalidTextRepresentation — the cast-guard's whole
    # point). The fence's "n/a" alone cannot catch the lost-backslash class.
    imports(:receipt_understood).update!(extracted_data: imports(:receipt_understood).extracted_data.merge("total" => "12x34"))
    assert_empty DocumentLink::Search.new(family: @family, filters: { amount_min: "0" }).relation.pluck(:id)
  end

  test "a junk amount bound is ignored instead of raising" do
    unfiltered = DocumentLink::Search.new(family: @family).relation.pluck(:id)

    assert_equal unfiltered,
                 DocumentLink::Search.new(family: @family, filters: { amount_min: "abc", amount_max: "1..2" }).relation.pluck(:id)
  end

  # -- the status facet (M8 Task 9, Ruling M8-L2) ------------------------------

  test "the status filter narrows over DocumentLink::STATUSES and ignores unknown values" do
    queued = DocumentLink::Search.new(family: @family, filters: { status: %w[queued] }).relation.pluck(:id)
    assert_includes queued, document_links(:queued_receipt).id
    assert_not_includes queued, document_links(:unlinked_receipt).id

    # The facet's cleared states filter nothing; an unknown token never widens.
    unfiltered = DocumentLink::Search.new(family: @family).relation.pluck(:id)
    assert_equal unfiltered, DocumentLink::Search.new(family: @family, filters: { status: [] }).relation.pluck(:id)
    assert_equal unfiltered, DocumentLink::Search.new(family: @family, filters: { status: %w[bogus] }).relation.pluck(:id)
  end

  # -- the type facet (Milestone B, design D1) --------------------------------

  test "the type facet narrows to one source and defaults to all of them" do
    other = document_links(:queued_receipt)
    other.update!(source: "statement")

    all = DocumentLink::Search.new(family: @family, filters: {}).relation
    receipts = DocumentLink::Search.new(family: @family, filters: { type: [ "receipt" ] }).relation

    assert_operator receipts.count, :<=, all.count
    assert receipts.all? { |l| l.source == "receipt" }
    assert_includes all.pluck(:id), other.id
    assert_not_includes receipts.pluck(:id), other.id
  end

  test "the type facet takes the receipts-bills chip's comma-joined value and drops unknown tokens" do
    statement = document_links(:queued_receipt)
    statement.update!(source: "statement")

    receipts_bills = DocumentLink::Search.new(family: @family, filters: { type: [ "receipt,bill" ] }).relation
    assert receipts_bills.pluck(:id).any?
    assert receipts_bills.all? { |l| l.source.in?(%w[receipt bill]) }
    assert_not_includes receipts_bills.pluck(:id), statement.id

    # The All chip ("all") and any unknown token are dropped, never widening.
    assert_equal DocumentLink::Search.new(family: @family).relation.pluck(:id),
                 DocumentLink::Search.new(family: @family, filters: { type: %w[bogus all] }).relation.pluck(:id)
  end

  # -- the "needs you" filter (Milestone B, design D5) ------------------------

  test "the attention filter narrows to the documents that need a person" do
    held = document_links(:queued_receipt)
    held.update!(failure_message: "no AI provider is configured")
    settled = document_links(:unlinked_receipt)

    ids = DocumentLink::Search.new(family: @family, filters: { attention: "1" }).relation.pluck(:id)
    assert_includes ids, held.id
    assert_not_includes ids, settled.id

    # A blank/absent attention filter filters nothing (the strip's cleared state).
    assert_equal DocumentLink::Search.new(family: @family).relation.pluck(:id),
                 DocumentLink::Search.new(family: @family, filters: { attention: "" }).relation.pluck(:id)
  end

  private
    # The expression the range/sort SQL evaluates — the display must equal it,
    # never merely "look plausible" (Ruling M8-C3).
    def document_date_sql(link)
      DocumentLink::Search.new(family: @family).relation.where(id: link.id)
                          .pick(Arel.sql(DocumentLink::Search::DOCUMENT_DATE_SQL))
    end

    def document_date_range(link, from, to)
      DocumentLink::Search.new(family: @family, filters: { date_from: from, date_to: to }).relation.pluck(:id)
    end
end
