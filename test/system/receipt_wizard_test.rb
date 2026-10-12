require "application_system_test_case"

class ReceiptWizardTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @account = accounts(:depository)
    users(:family_admin).update!(default_account: @account)
    # NO `DocumentLink.where(status: "unlinked").delete_all` here (M1's
    # document_bridge_test line): that line belongs to the entry-page link panel
    # this suite never touches, and it would delete the settled `unlinked_receipt`
    # row that `imports(:receipt_draft)` points at (the imports FK nullifies the
    # draft's document_link_id), breaking the second journey's seed.

    # Run jobs inline and stub only the paperless egress, so the whole bridge
    # (wizard intake -> post -> poll -> unlinked -> snapshot -> understanding)
    # runs in this process. #file is stubbed yielded, not returned — Mocha
    # `.returns` never invokes a passed block.
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    # Ruling 8 (M1): the inline adapter cannot enqueue FUTURE jobs, so the
    # upload job's set(wait:) poll handoff is folded to an immediate perform.
    Paperless::TaskPollJob.stubs(:set).returns(Paperless::TaskPollJob)
    Paperless::Client.any_instance.stubs(:configured?).returns(true)
    Paperless.stubs(:tag_id).returns(1)
    Paperless::Client.any_instance.stubs(:post_document).returns("task-uuid")
    Paperless::Client.any_instance.stubs(:task).returns(
      Paperless::Task.new(status: :success, document_id: 6001, duplicate_of: nil, error_message: nil)
    )
    Paperless::Client.any_instance.stubs(:file).yields(
      "", OpenStruct.new(status: 200, response_headers: { "content-type" => "image/png" })
    )
    # The snapshot the settle path records (Task 1) — total AND date, so the
    # inline OCR lands `understood` under the F8 rule.
    Paperless::Client.any_instance.stubs(:document).returns(
      Paperless::Document.new(id: 6001, title: "receipt.png", created: Date.current, tag_ids: [],
                              content: "LATTE LANE CAFE\n2026-09-14\nTOTAL $4.75")
    )
    # Ruling-8-class fold (M1): the inline adapter cannot enqueue FUTURE jobs,
    # and Import#publish's post-commit `family.sync_later` fan-out enqueues them
    # deep inside Sync's finalization (proven: the publish POST 500s with
    # `NotImplementedError: Use a queueing backend to enqueue jobs in the
    # future` without this stub). The family sync fan-out is not the surface
    # under test — the reviewed publish's money write is; production is
    # untouched (Sidekiq runs the real sync). Same discipline as the
    # `Paperless::TaskPollJob.set` fold above.
    Family.any_instance.stubs(:sync_later)
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "the New popup takes a resolved receipt straight to the archive" do
    # (M8 Task 9, Ruling M8-L1 decisions 1/2) family_admin's bills default
    # resolves the prefill ladder: choosing the file submits instantly (no
    # Continue button) and the wizard finishes on the archive in the main
    # chrome — no step 3.
    visit root_path
    click_on I18n.t("pages.dashboard.new")

    assert_text I18n.t("accounts.new.receipt_or_bill")
    assert_text I18n.t("accounts.new.statement")
    click_on I18n.t("accounts.new.receipt_or_bill")

    # The tile click swaps the #modal Turbo frame, and the wizard's file rows
    # render ONLY when step 2's frame response lands — wait for the wizard
    # container (and for the inputs to exist — visible: :all, since they render
    # class="hidden") FIRST, then de-hide, then attach (the same order the
    # drag_and_drop_import_test.rb:20-26 workaround uses before its own
    # attach_file). The script is scoped to the two inputs the wizard actually
    # renders at this point, not every hidden file input on the page.
    assert_text I18n.t("document_wizards.new.capture")
    assert_selector "#modal [data-controller~='receipt-dropzone']" # the one drop zone
    assert_selector "#modal input[type='file'][name='document_camera']", visible: :all
    assert_selector "#modal input[type='file'][name='document_file']", visible: :all
    execute_script("document.querySelectorAll(\"#modal input[type='file'][name='document_camera'], #modal input[type='file'][name='document_file']\").forEach(function (el) { el.classList.remove('hidden'); el.style.display = 'block'; })")
    assert_selector "input[type='file'][capture='environment']"
    attach_file "document_file", file_fixture("receipts/receipt.png")

    # No further click: the change submits and the wizard lands on the archive.
    assert_current_path documents_path
    draft = ReceiptImport.order(:created_at).last
    assert_equal @account, draft.account
    # The inline harness settles the OCR during the POST (the stub content
    # parses), so the row already carries the ready affordance.
    assert_equal "understood", draft.understanding_state
    within "#document_link_#{draft.document_link.id}" do
      assert_link I18n.t("imports.receipt_import.review_details")
    end
  end

  test "an ambiguous account choice still asks at step 3 and then lands on the archive" do
    # (M8 Task 9) family_member reaches two accounts with no default: the
    # ladder cannot resolve, so the wizard still asks — step 3, in the modal it
    # has always used. Its Finish is fire-and-forget and lands on the archive.
    sign_in users(:family_member)
    visit root_path
    click_on I18n.t("pages.dashboard.new")
    click_on I18n.t("accounts.new.receipt_or_bill")

    assert_text I18n.t("document_wizards.new.capture")
    assert_selector "#modal input[type='file'][name='document_file']", visible: :all
    execute_script("document.querySelectorAll(\"#modal input[type='file'][name='document_camera'], #modal input[type='file'][name='document_file']\").forEach(function (el) { el.classList.remove('hidden'); el.style.display = 'block'; })")
    attach_file "document_file", file_fixture("receipts/receipt.png")

    # onchange auto-submits; the modal swaps to step 3 (a native select, so
    # Capybara's own `select` drives it — Task 5's F1 repair).
    assert_text I18n.t("import.accounts.show.title")
    select @account.name, from: I18n.t("import.accounts.show.account_label")
    click_on I18n.t("import.accounts.show.finish")

    assert_current_path documents_path
    draft = ReceiptImport.order(:created_at).last
    assert_equal @account, draft.account
    assert_equal "understood", draft.understanding_state
  end

  test "the one-tap source override and Add details ride the drop" do
    # (M8 Task 9, Ruling M8-L1 decision 4) The override and the title are chosen
    # BEFORE the file — choosing the file submits instantly.
    visit root_path
    click_on I18n.t("pages.dashboard.new")
    click_on I18n.t("accounts.new.receipt_or_bill")

    assert_text I18n.t("document_wizards.new.capture")
    choose I18n.t("documents.source.bill") # one tap: receipt.png would guess receipt
    find("summary", text: I18n.t("document_wizards.new.add_details")).click
    fill_in "title", with: "Laptop purchase"
    assert_selector "#modal input[type='file'][name='document_file']", visible: :all
    execute_script("document.querySelectorAll(\"#modal input[type='file'][name='document_camera'], #modal input[type='file'][name='document_file']\").forEach(function (el) { el.classList.remove('hidden'); el.style.display = 'block'; })")
    attach_file "document_file", file_fixture("receipts/receipt.png")

    assert_current_path documents_path
    link = DocumentLink.order(:created_at).last
    assert_equal "bill", link.source
    assert_equal "Laptop purchase", link.title
  end

  test "a settling draft flips its row to the review affordance without a reload" do
    # (M8 Task 9, Ruling M8-L1 decision 3) The archive row re-renders in place
    # when the draft's understanding settles — no manual reload.
    draft = imports(:receipt_draft)
    link = draft.document_link
    visit documents_path
    within "#document_link_#{link.id}" do
      assert_button I18n.t("imports.receipt_import.reading"), disabled: true
    end

    # Settle outside the browser: snapshot, then the understanding job (which
    # broadcasts the replaced row).
    link.record_content!(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))
    ReceiptImport::UnderstandJob.perform_now(draft.id)

    # The row's GET actions render as icon links (the label lives in title and
    # aria-label), so the flip is pinned by the Review-details href — absent in
    # the "Reading…" row. The stream subscription may still be connecting on a
    # fast machine, and the row replace is idempotent: re-broadcast until the
    # flipped row lands.
    page.document.synchronize(Capybara.default_max_wait_time) do
      unless page.has_selector?("#document_link_#{link.id} a[href='#{import_path(draft)}']")
        link.broadcast_row_update!
        raise Capybara::ExpectationNotMet, "the row has not flipped to the review affordance yet"
      end
    end

    within "#document_link_#{link.id}" do
      assert_selector "a[href='#{import_path(draft)}'][title='#{I18n.t("imports.receipt_import.review_details")}']"
      assert_no_button I18n.t("imports.receipt_import.reading")
    end
  end

  test "a settled receipt reviews and publishes into one expense" do
    # Seed the receipt_draft fixture directly (its document_link row survives
    # setup — see the F10 repair above) and settle its snapshot inline.
    draft = imports(:receipt_draft)
    draft.update!(account: @account)
    draft.document_link.record_content!(File.read(Rails.root.join("test/fixtures/files/receipts/wizard_latte.txt")))
    ReceiptImport::UnderstandJob.perform_now(draft.id)

    # (Ruling M7-L4, 2026-10-11) The plan's fence navigated the archive card's
    # "Review details" affordance (`documents_path(source: "receipt,bill")` +
    # `imports.receipt_import.review_details`) — but that affordance is Task 9
    # material and moved to M8 with the archive redesign, so it never landed in
    # M7 (RED on the fenced form: `Translation missing:
    # en.imports.receipt_import.review_details` — the M8 plan's Task 2 owns the
    # key now). The publish acceptance itself is unchanged: reach the reviewed
    # screen through the route the wizard ends on (decision 11 — the review
    # page), which is the surface under test here.
    visit import_path(draft)

    assert_text I18n.t("imports.receipt_import.total")
    click_on I18n.t("imports.receipt_import.publish"), wait: 10

    # The publish is a Turbo POST; Task 7's partial renders the publish button
    # only while `publishable?`, so its disappearance is the page-level
    # post-publish signal. But this environment's driver has raced this shape
    # before (M1 Ruling 10: a bare DB read after a Turbo click read nil on 4 of
    # 15 runs — reproduced here before the sync below was added: the click
    # returns before the POST commits), so the READ itself is synced too — the
    # repo's own pattern (release_highlights_test.rb:36-41), which the plan's
    # fence N1 note cites.
    assert_no_button I18n.t("imports.receipt_import.publish")

    entry = nil
    page.document.synchronize do
      # (Task 8) The reviewed publish mints the DOCUMENT identity — the link id,
      # not paperless_document_id (a column Task 12 deletes).
      entry = Entry.find_by(external_id: "document:#{draft.document_link.id}")
      raise Capybara::ElementNotFound, "the reviewed publish is not saved yet" unless entry
    end

    assert_equal "document", entry.source
  end
end
