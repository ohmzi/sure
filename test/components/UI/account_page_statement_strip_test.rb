require "test_helper"

# The account page's statement strip (the owner's redesign, 2026-10-17): the
# latest statements, a month each, marked by whether each one checks out.
class UI::AccountPageStatementStripTest < ViewComponent::TestCase
  setup do
    @account = accounts(:depository)
    Current.session = users(:family_admin).sessions.create!
  end

  teardown { Current.reset }

  def statement_for(month_start, **attrs)
    file = Tempfile.new([ "statement", ".pdf" ])
    file.binmode
    file.write(file_fixture("receipts/statement.pdf").binread + "\n%#{SecureRandom.hex(8)}")
    file.rewind
    statement = AccountStatement.create_from_upload!(
      family: @account.family, account: @account,
      file: Rack::Test::UploadedFile.new(file.path, "application/pdf")
    )
    statement.update_columns(period_start_on: month_start, period_end_on: month_start.end_of_month, **attrs)
    statement
  end

  test "lists the latest statements oldest first, each with its check, and no more than six" do
    months = (0..7).map { |i| Date.new(2026, 1, 1) + i.months }
    months.each { |m| statement_for(m) }

    checks = UI::AccountPage.new(account: @account).recent_statement_checks

    assert_equal 6, checks.size
    assert_equal months.last(6).map(&:end_of_month), checks.map { |statement, _| statement.period_end_on }
    assert checks.all? { |_, status| %w[matched mismatched unavailable].include?(status) }
  end

  test "the account page uploads a document from a floating action button" do
    render_inline(UI::AccountPage.new(account: @account, can_manage_statements: true))

    assert_no_text I18n.t("account_statements.form.upload_title")
    assert_selector "label[for='account-statement-fab-#{@account.id}']"
    assert_selector "label[aria-label='#{I18n.t("account_statements.form.upload_fab")}']"
    assert_selector "input[type='file'][data-auto-submit-form-target='auto']", visible: :all
  end

  test "an account with no statements has no strip" do
    assert_empty UI::AccountPage.new(account: @account).recent_statement_checks

    render_inline(UI::AccountPage.new(account: @account))
    assert_no_selector "[data-statement-strip]"
  end
end
