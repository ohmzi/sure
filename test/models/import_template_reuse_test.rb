require "test_helper"

class ImportTemplateReuseTest < ActiveSupport::TestCase
  setup do
    @family  = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "a completed import becomes the suggested template for the same account and type" do
    first = TransactionImport.create!(family: @family, account: @account)
    first.update!(
      raw_file_str: "date,amount,name\n2024-01-01,-5.00,Coffee\n",
      date_col_label: "date", amount_col_label: "amount", name_col_label: "name",
      date_format: "%Y-%m-%d", number_format: "1,234.56", signage_convention: "inflows_positive"
    )
    first.update!(status: :complete)

    second = TransactionImport.create!(family: @family, account: @account)

    assert_equal first, second.suggested_template
  end

  test "apply_template! copies the column mapping onto the new import" do
    first = TransactionImport.create!(family: @family, account: @account)
    first.update!(
      raw_file_str: "Date,Amount,Description\n2024-01-01,-5.00,Coffee\n",
      date_col_label: "Date", amount_col_label: "Amount", name_col_label: "Description",
      date_format: "%d/%m/%Y", number_format: "1.234,56", signage_convention: "inflows_negative"
    )
    first.update!(status: :complete)

    second = TransactionImport.create!(family: @family, account: @account)
    second.apply_template!(second.suggested_template)

    assert_equal "Date", second.reload.date_col_label
    assert_equal "Amount", second.amount_col_label
    assert_equal "Description", second.name_col_label
    assert_equal "%d/%m/%Y", second.date_format
    assert_equal "1.234,56", second.number_format
    assert_equal "inflows_negative", second.signage_convention
  end

  test "suggested_template is scoped to the account, not the family" do
    other_account = accounts(:credit_card)

    first = TransactionImport.create!(family: @family, account: @account)
    first.update!(raw_file_str: "date,amount\n2024-01-01,-5.00\n", date_col_label: "date", amount_col_label: "amount")
    first.update!(status: :complete)

    unrelated = TransactionImport.create!(family: @family, account: other_account)

    assert_nil unrelated.suggested_template
  end
end
