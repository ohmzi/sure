require "application_system_test_case"

# Every transaction says where the money came from — or says it was entered by
# hand (spec N13, the owner's second complaint: "each transaction that's listed
# doesn't point to exactly where it came from, so I can't verify"). The resolver
# is Task 5's `EntryProvenance`; this file pins its render on the drawer.
class DocumentProvenanceTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "a transaction from a document says so, and links to it" do
    entry = entries(:transaction_entry)
    link = document_links(:unlinked_receipt)
    link.update!(entry_id: entry.id)
    visit transaction_path(entry)

    assert_text I18n.t("entries.provenance.document")
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.document")
    assert_selector "[data-provenance] a[href='#{viewer_document_path(link)}']"
  end

  test "a transaction typed by hand says that, and claims no document" do
    entry = entries(:transaction_entry)
    entry.update!(source: nil, external_id: nil, import: nil, import_locked: false)
    entry.document_links.delete_all
    visit transaction_path(entry.reload)

    assert_text I18n.t("entries.provenance.manual")

    # Scoped to the provenance fragment, not the whole page: the sidebar always
    # carries a Documents nav link, so an unscoped `a[href*='documents']` would
    # fail (or pass) for a reason that is not the claim under test. A manual
    # entry's fragment shows its own pill and links to no document at all.
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.manual")
    assert_no_selector "[data-provenance] a"
  end

  test "a value changed after the read is marked as edited" do
    entry = entries(:transaction_entry)
    link = document_links(:understood_receipt_link)
    link.update!(entry_id: entry.id)
    entry.update!(amount: entry.amount + 10)
    visit transaction_path(entry.reload)

    assert_text I18n.t("entries.provenance.edited")
    assert_selector "[data-provenance]", text: I18n.t("entries.provenance.edited")
  end
end
