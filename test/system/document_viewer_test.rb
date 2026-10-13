require "application_system_test_case"

# The viewer's two modes (Milestone B Task 4, design D4): a document with a read
# worth showing opens as a split — the document left, what was understood right —
# a document with no read states the reason and the two ways forward, and a
# document still being read says so. `understood_receipt_link` carries a succeeded
# extraction fixture; `held_bill` is unread with the live host's hold reason;
# `queued_receipt` is in flight.
class DocumentViewerTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "a read document opens split, with the read, the doubts and the checks" do
    link = document_links(:understood_receipt_link)
    visit viewer_document_path(link)

    # The split: the document itself on the left, the panel on the right.
    assert_selector "img[data-document-viewer-target='image'][src='#{file_document_path(link, kind: "original")}']"

    within "[data-document-understanding]" do
      # what it decided: the settled class, its confidence, the resolved account
      assert_text I18n.t("documents.understanding.title")
      assert_text I18n.t("documents.source.receipt")
      assert_text I18n.t("documents.understanding.confidence", percent: 96)

      # what it read: each field with its confidence, the unsure one marked
      within "[data-field='total']" do
        assert_text "12.00"
        assert_text I18n.t("documents.understanding.confidence", percent: 54)
        assert_text I18n.t("documents.understanding.check_this")
      end
      within "[data-field='payee']" do
        assert_text "Latte Lane"
        assert_no_text I18n.t("documents.understanding.check_this")
      end

      # the checks: a pass, a "not checkable", and a fail are three states
      assert_text "OCR and AI agree on the total"
      assert_text I18n.t("documents.understanding.not_checkable")

      # what it became — each outcome links to the thing it produced
      assert_text I18n.t("documents.understanding.state.understood")
      assert_selector "a[href='#{import_path(imports(:receipt_understood))}']",
                      text: I18n.t("documents.understanding.state.understood")
    end
  end

  test "an unread document states the reason and the two ways forward" do
    link = document_links(:held_bill)
    # The live host's exact state: no provider configured, so the read was held
    # with its reason and no extraction was written.
    link.update_columns(failure_message: "no AI provider is configured")

    visit viewer_document_path(link)

    within "[data-document-understanding]" do
      assert_text I18n.t("documents.understanding.not_read_yet")
      assert_text "no AI provider is configured"
      assert_selector "a[href='#{settings_hosting_path}']",
                      text: I18n.t("documents.understanding.unread.set_up_provider")
      assert_selector "a[href='#{new_transaction_path}']",
                      text: I18n.t("documents.understanding.unread.enter_by_hand")
    end
  end

  test "a document being read says Reading, not that it cannot be read" do
    # Just uploaded: queued, nothing held, no read yet. The viewer must not
    # report it as unread, nor offer a provider to configure.
    link = document_links(:queued_receipt)

    visit viewer_document_path(link)

    within "[data-document-understanding]" do
      assert_text I18n.t("documents.understanding.reading")
      assert_no_text I18n.t("documents.understanding.not_read_yet")
      assert_no_selector "a[href='#{settings_hosting_path}']"
    end
  end

  test "the document's own page renders the same split without the dialog" do
    link = document_links(:understood_receipt_link)
    visit document_path(link)

    assert_no_selector "dialog[open]"
    assert_text I18n.t("documents.understanding.title")
    assert_selector "a[href='#{documents_path}']", text: I18n.t("documents.show.back")
  end
end
