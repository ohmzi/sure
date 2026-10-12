require "test_helper"
require "zip"

class Family::ExportImportRoundTripTest < ActiveSupport::TestCase
  setup do
    @source = families(:empty)
    # Category has no `classification` attribute (the column is `classification_unused`,
    # default "expense"); pass only name/color (lucide_icon defaults to "shapes").
    @category = @source.categories.create!(name: "Groceries", color: "#00FF00")
    @budget = @source.budgets.create!(
      start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 1, 31),
      budgeted_spending: 3000, expected_income: 5000, currency: "USD", user_id: nil
    )
    @budget.budget_categories.create!(
      category: @category, budgeted_spending: 500, currency: "USD",
      rollover_enabled: true, rolled_over_amount: 25,
      target_type: "monthly_assign", target_amount: 500
    )
  end

  test "envelope fields survive export and import" do
    ndjson = extract_ndjson(Family::DataExporter.new(@source).generate_export)

    target = families(:dylan_family)
    Family::DataImporter.new(target, ndjson).import!

    imported = target.budgets.find_by(start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 1, 31))
    assert imported, "budget did not round-trip"
    assert_nil imported.user_id, "household budget must stay user_id nil"

    bc = imported.budget_categories.joins(:category).find_by!(categories: { name: "Groceries" })
    assert_equal 500.to_d, bc.budgeted_spending
    assert bc.rollover_enabled, "rollover_enabled must survive"
    assert_equal 25.to_d, bc.rolled_over_amount, "rolled_over_amount must survive"
    assert_equal "monthly_assign", bc.target_type
    assert_equal 500.to_d, bc.target_amount
  end

  test "a resolvable user_id is preserved on import" do
    admin = users(:family_admin)
    ndjson = build_ndjson([
      { type: "Budget", data: {
          id: "b1", start_date: "2024-02-01", end_date: "2024-02-29",
          budgeted_spending: "3000.00", expected_income: "5000.00",
          currency: "USD", user_id: admin.id } }
    ])

    Family::DataImporter.new(admin.family, ndjson).import!
    assert_equal admin.id, admin.family.budgets.find_by(start_date: Date.new(2024, 2, 1)).user_id
  end

  test "an unresolvable user_id degrades a personal budget to household" do
    ndjson = build_ndjson([
      { type: "Budget", data: {
          id: "b1", start_date: "2024-03-01", end_date: "2024-03-31",
          budgeted_spending: "3000.00", expected_income: "5000.00",
          currency: "USD", user_id: SecureRandom.uuid } }
    ])

    target = families(:dylan_family)
    Family::DataImporter.new(target, ndjson).import!
    assert_nil target.budgets.find_by(start_date: Date.new(2024, 3, 1)).user_id
  end

  private

    def extract_ndjson(zip_io)
      contents = nil
      Zip::File.open_buffer(zip_io) do |zip|
        zip.each { |entry| contents = entry.get_input_stream.read if entry.name == "all.ndjson" }
      end
      contents
    end

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end
end
