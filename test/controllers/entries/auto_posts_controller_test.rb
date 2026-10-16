require "test_helper"

# Undo (spec N6): the audit surface that makes shipping the auto-post gate live
# defensible. It reverses exactly what the MACHINE wrote -- refusing anything a
# human typed -- and it must not destroy the document that was its cause.
class Entries::AutoPostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("auto-post-undo"))
    @previous_staging = ENV["SURE_DOCUMENT_STORE_DIR"]
    ENV["SURE_DOCUMENT_STORE_DIR"] = @tmp.to_s

    sign_in users(:family_admin)
    @entry = entries(:transaction_entry)
    @entry.update!(ai_posted_at: Time.current)
  end

  teardown do
    ENV["SURE_DOCUMENT_STORE_DIR"] = @previous_staging
    FileUtils.remove_entry(@tmp) if @tmp.exist?
  end

  # Writes bytes at the store root for the row and returns the path.
  def stage_bytes(link, bytes)
    DocumentLink::Staging.write(io: StringIO.new(bytes), id: link.id)
  end

  test "undo removes the entry a machine wrote" do
    assert_difference -> { Entry.count }, -1 do
      delete entry_auto_post_path(@entry)
    end
    assert_redirected_to transactions_path
    assert_equal I18n.t("entries.auto_posts.destroy.undone"), flash[:notice]
  end

  test "undo refuses an entry a human wrote" do
    @entry.update!(ai_posted_at: nil)

    assert_no_difference -> { Entry.count } do
      delete entry_auto_post_path(@entry)
    end
    assert_response :unprocessable_content
  end

  # A reconciled row is bank-evidenced (spec N9): the statement proved this
  # charge. Reversing it would drop money a bank record attested to and orphan
  # the statement's reconciled chip, so the undo refuses it and leaves the row
  # exactly as it was.
  test "undo refuses a reconciled entry and leaves it in place" do
    @entry.update!(reconciled_at: Time.current)
    assert @entry.reconciled?

    assert_no_difference -> { Entry.count } do
      delete entry_auto_post_path(@entry)
    end

    assert_response :unprocessable_content
    assert_equal I18n.t("entries.auto_posts.destroy.reconciled"), flash[:alert]
    assert Entry.exists?(@entry.id), "the reconciled row survives the refused undo"
  end

  # 🔴 The document must not be collateral damage. An entry the machine wrote
  # exists because a person handed it a document; undoing the entry detaches the
  # link and leaves the bytes, the read and the tile exactly where they were.
  test "undo releases the document and leaves it alive, readable and in the grid" do
    link = document_links(:understood_receipt_link)
    link.update_columns(stored_path: stage_bytes(link, "receipt-bytes"),
                        content_type: "image/png")
    link.link_to_entry!(@entry)
    assert_equal @entry.id, link.reload.entry_id, "the document is attached before the undo"
    title = link.title

    delete entry_auto_post_path(@entry)

    assert_not Entry.exists?(@entry.id), "the machine's transaction is gone"

    link.reload
    assert_equal "unlinked", link.status
    assert_nil link.entry_id, "the link is detached, not destroyed"
    assert DocumentLink.exists?(link.id), "the document row survives its entry"
    assert link.stored_path.present?, "its bytes stay the document's"
    assert link.extraction.present?, "its read stays with it"

    # Still served: the bytes are the user's.
    get file_document_path(link, kind: "original")
    assert_response :success
    assert_equal "receipt-bytes", response.body

    # Still readable: the viewer still opens it.
    get viewer_document_path(link)
    assert_response :success, "the document is still readable after its entry is undone"

    # Still in the Documents grid.
    get documents_path
    assert_response :success
    assert_match title, response.body
  end

  # The undo is DURABLE (the carried-in Task 9 gap): a reprocess re-enqueues the
  # auto-post because the undo cleared the draft's `data_committed?`. The
  # document records the reversal, so the machine cannot silently re-post what
  # the user took back.
  test "undo records the reversal on the document, so a reprocess cannot re-post" do
    link = document_links(:understood_receipt_link)
    link.link_to_entry!(@entry)
    assert_not link.reload.auto_post_undone?

    delete entry_auto_post_path(@entry)

    assert link.reload.auto_post_undone?,
           "the document must remember that its auto-post was undone"
  end

  # The undo releases only the links that point at THIS entry. A document linked
  # to some other transaction is not this undo's to touch (Task 7's scoping
  # precedent: detach by the link's own id and the entry it belongs to).
  test "undo does not detach another entry's document" do
    keep = document_links(:linked_receipt) # attached to entries(:transaction)
    raising = document_links(:understood_receipt_link)
    raising.link_to_entry!(@entry)

    delete entry_auto_post_path(@entry)

    keep.reload
    assert_equal "linked", keep.status
    assert_equal entries(:transaction).id, keep.entry_id
  end

  # The reversal is recorded on exactly the document the entry's OWN identity
  # came from (review finding 5): the auto-post writer mints
  # `external_id "document:<link id>"`. Marking EVERY link on the entry would
  # also stamp a statement that merely corroborated this row, wrongly refusing a
  # receipt later matched to that statement.
  test "undo marks only the document the entry's own identity came from" do
    receipt_link = document_links(:understood_receipt_link)
    receipt_link.link_to_entry!(@entry)
    @entry.update!(external_id: "document:#{receipt_link.id}", source: "document")

    # A statement later corroborated this entry (Task 7's claim!): a second link
    # hangs on the same row. The undo must not reach it.
    corroborating_link = document_links(:linked_receipt)
    corroborating_link.link_to_entry!(@entry)

    delete entry_auto_post_path(@entry)

    assert receipt_link.reload.auto_post_undone?,
           "the entry's own document records the reversal"
    assert_not corroborating_link.reload.auto_post_undone?,
               "a corroborating document must not be stamped undone by this undo"
  end

  # Deleting money must not be reachable for an account the user cannot write.
  test "undo refuses a row outside the current family" do
    sign_in users(:empty)

    assert_no_difference -> { Entry.count } do
      delete entry_auto_post_path(@entry)
    end
    assert_response :not_found
  end

  # The affordance is an audit surface: the row must say the app added this, and
  # link the document it came from, so undo is an informed act.
  test "the row and the drawer name the app as the author and link its document" do
    @entry.update!(import: imports(:receipt_understood))
    document = imports(:receipt_understood).document_link
    undo_action = entry_auto_post_path(@entry)

    get transactions_path
    assert_response :success
    assert_select "form[action=?][method='post']", undo_action do
      assert_select "input[name='_method'][value='delete']"
    end
    assert_match I18n.t("entries.auto_post.badge"), response.body
    assert_select "[data-auto-post='#{dom_id(@entry)}'] a[href=?]", viewer_document_path(document)

    get transaction_path(@entry)
    assert_response :success
    assert_select "form[action=?]", undo_action
    assert_match I18n.t("entries.auto_post.badge"), response.body
  end

  test "a hand-entered row carries no undo affordance" do
    @entry.update!(import: imports(:receipt_understood), ai_posted_at: nil)

    get transactions_path
    assert_response :success
    assert_select "form[action=?]", entry_auto_post_path(@entry), count: 0
    assert_no_match I18n.t("entries.auto_post.badge"), response.body
  end

  # The marker is not a user parameter: nothing in the transactions update
  # permits `ai_posted_at`, so a person cannot label their own row as
  # machine-written and forge it into the audit filter.
  test "a person cannot mark their own row as machine-written" do
    human = entries(:depository_transaction)
    assert_nil human.ai_posted_at

    patch transaction_path(human), params: { entry: { ai_posted_at: Time.current.iso8601 } }

    assert_nil human.reload.ai_posted_at, "ai_posted_at must not be mass-assignable"
    assert_not_includes EntrySearch.new(ai_posted: "true").build_query(Entry.all), human
  end

  # The filter the owner audits with, wired end to end through the ledger.
  test "the ledger filters to exactly the machine's writes" do
    human = entries(:depository_transaction)
    human.update!(ai_posted_at: nil)

    get transactions_path(q: { ai_posted: "true" })

    assert_response :success
    assert_match @entry.name, response.body
    assert_no_match human.name, response.body
  end
end
