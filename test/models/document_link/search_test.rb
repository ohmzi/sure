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

  # -- the tag facet (M8 Task 6) ----------------------------------------------

  test "the tag filter matches by array overlap on the stored snapshot" do
    document_links(:unlinked_receipt).update!(paperless_tags: %w[ohmzbudget receipt])
    document_links(:held_bill).update!(paperless_tags: %w[ohmzbudget bill])

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
end
