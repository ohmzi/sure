require "test_helper"

class Settings::LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  test "admin can view family LLM usage" do
    sign_in users(:family_admin)
    get settings_llm_usage_path
    assert_response :success
    assert_includes response.body, I18n.l(LlmUsage::PRICING_VERIFIED_ON)
  end

  test "non-admin member cannot view family LLM usage" do
    sign_in users(:family_member)
    get settings_llm_usage_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end

  test "guest cannot view family LLM usage" do
    sign_in users(:intro_user)
    get settings_llm_usage_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end

  test "shows the latest categorization evaluation's accuracy and abstention rate" do
    run = completed_categorization_run([
      [ "Food & Drink", "Food & Drink", true ],
      [ "Income", "Income", true ],
      [ nil, nil, true ],
      [ "Food & Drink", "Income", false ]
    ])

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_quality")
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_accuracy")
    assert_includes response.body, "75.0%"
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_abstention")
    assert_includes response.body, "25.0%"
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_by_category")
    assert_includes response.body, "Food &amp; Drink"
    assert_includes response.body, run.model
  end

  test "shows an empty state when no categorization evaluation has completed" do
    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_quality_empty_title")
    assert_not_includes response.body, I18n.t("settings.llm_usages.show.categorization_accuracy")
  end

  test "shows a correction rate from the household's automatic assignments" do
    completed_categorization_run([ [ "Food & Drink", "Food & Drink", true ] ])
    transaction = transactions(:transaction_entry)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    transaction.update!(category_id: categories(:food_and_drink).id)

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_correction")
  end

  test "omits the correction rate when nothing was assigned automatically" do
    completed_categorization_run([ [ "Food & Drink", "Food & Drink", true ] ])

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.llm_usages.show.categorization_correction")
  end

  private
    # results: [expected, actual, correct] triples, one per sample.
    def completed_categorization_run(results)
      dataset = Eval::Dataset.create!(
        name: "llm_usage_quality_#{SecureRandom.hex(4)}",
        eval_type: "categorization",
        version: "1.0"
      )
      run = Eval::Run.create!(
        dataset: dataset,
        provider: "openai",
        model: "quality-model",
        status: "running",
        started_at: 2.minutes.ago
      )

      results.each do |expected, actual, correct|
        sample = dataset.samples.create!(
          input_data: { "description" => expected.to_s },
          expected_output: { "category_name" => expected },
          context_data: {},
          difficulty: "easy"
        )
        run.results.create!(
          sample: sample,
          actual_output: { "category_name" => actual },
          correct: correct,
          exact_match: expected == actual,
          hierarchical_match: expected == actual,
          null_expected: expected.nil?,
          null_returned: actual.nil?
        )
      end

      run.complete!(Eval::Metrics::CategorizationMetrics.new(run).calculate)
      run
    end
end
