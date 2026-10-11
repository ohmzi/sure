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
end
