require "application_system_test_case"

# The dropzone's handoff branches (design N11): a bank export dropped on the
# Documents page is handed to the import pipeline that knows how to read it, and
# the browser follows the answer to that pipeline's screen.
#
# This is the only test that exercises the fetch → 302 → Turbo.visit path. The
# intakes controller's own test pins the 302, but only a real browser proves the
# dropzone NAVIGATES to it: `fetch` follows a 302 as a GET that never yields a
# turbo-stream body, so before the redirect handling in the Stimulus controller a
# successful import reported itself as a failure (and a retry would have created
# a second import).
class DocumentsIntakeTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "a CSV dropped on the documents page opens the import configuration screen" do
    visit documents_path

    # The bar's picker is a hidden input behind the Add document button. The
    # chosen file's change is what uploads it — the SAME upload() path a real
    # drag/drop takes, though no real dragover/drop event is driven here (no
    # test does; see the report).
    assert_selector "input[type='file'][name='document']", visible: :all
    execute_script("document.querySelector(\"input[type='file'][name='document']\").classList.remove('hidden')")
    attach_file "document", file_fixture("imports/transactions.csv")

    # The redirect was followed as a navigation, not reported as a failure: we
    # are on the configuration screen and its form is rendered.
    assert_current_path %r{\A/imports/[\w-]+/configuration\z}
    assert_selector "[data-controller~='import']", wait: 5

    # ...and the import it opened actually carries the file to map.
    assert Import.order(:created_at).last.raw_file_str.present?
  end
end
