require "application_system_test_case"

# The bulk edit sheet (the owner's design, 2026-10-19): only the fields filled
# in change. Its tag picker always carries a blank tag field, and a blank
# `tag_ids` tells the server to replace the tags, so editing just the
# category of a few transactions must not wipe their tags.
class BulkEditSheetTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @entry = entries(:transaction)
    @tags = @entry.transaction.tags.to_a
  end

  test "changing only the category keeps the transactions' tags" do
    assert_not_empty @tags, "the fixture transaction should start with tags"

    open_bulk_edit
    within("dialog[open]") do
      assert_text I18n.t("transactions.bulk_updates.new.subtitle")
      assert_no_selector ".translation_missing"
      assert_text I18n.t("transactions.bulk_updates.new.date_label")
      select_category(categories(:income).name)
      assert_selector "[data-changed]", count: 1
      click_button I18n.t("transactions.bulk_updates.new.save")
    end

    assert_text "transactions updated"
    @entry.reload
    assert_equal categories(:income), @entry.transaction.category
    assert_equal @tags.map(&:id).sort, @entry.transaction.tags.reload.map(&:id).sort
  end

  private
    def open_bulk_edit
      page.driver.browser.manage.window.resize_to(1440, 900)
      visit transactions_url
      find("##{ActionView::RecordIdentifier.dom_id(@entry, "selection")}").check
      find("a[href='#{new_transactions_bulk_update_path}']").click
      assert_selector "dialog[open]"
    end

    def select_category(name)
      find("[data-bulk-edit-summary-target='row']", text: I18n.t("transactions.bulk_updates.new.category_label")).find("button", match: :first).click
      find("[role='option']", text: name, match: :first).click
    end
end
