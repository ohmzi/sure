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
    assert_includes response.body,
                    ERB::Util.html_escape(I18n.t("settings.llm_usages.show.categorization_quality_empty_description"))
    assert_not_includes response.body, I18n.t("settings.llm_usages.show.categorization_accuracy")
  end

  test "ignores another family's completed evaluation" do
    completed_categorization_run(
      [ [ "Food & Drink", "Food & Drink", true ] ],
      family: families(:empty)
    )

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_quality_empty_title")
    assert_not_includes response.body, "100.0%"
  end

  test "suppresses accuracy and annotates a run with errored samples" do
    completed_categorization_run([
      [ "Food & Drink", "Food & Drink", true ],
      [ "Food & Drink", nil, false, "provider outage" ]
    ])

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_not_reported")
    assert_includes response.body,
                    I18n.t("settings.llm_usages.show.categorization_accuracy_errored", errored: 1, total: 2)
    assert_not_includes response.body, "50.0%", "the stored accuracy counts the errored sample as wrong"
  end

  test "shows an empty state when the completed run has no results" do
    completed_categorization_run([])

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_includes response.body, I18n.t("settings.llm_usages.show.categorization_quality_empty_title")
    assert_not_includes response.body, I18n.t("settings.llm_usages.show.categorization_accuracy")
  end

  test "does not show a correction rate" do
    completed_categorization_run([ [ "Food & Drink", "Food & Drink", true ] ])

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_not_includes response.body, "Correction rate"
  end

  private
    # results: [expected, actual, correct, error] entries; error is optional.
    def completed_categorization_run(results, family: families(:dylan_family))
      dataset = Eval::Dataset.create!(
        name: "llm_usage_quality_#{SecureRandom.hex(4)}",
        eval_type: "categorization",
        version: "1.0",
        metadata: family ? { "family_id" => family.id } : {}
      )
      run = Eval::Run.create!(
        dataset: dataset,
        provider: "openai",
        model: "quality-model",
        status: "running",
        started_at: 2.minutes.ago
      )

      results.each do |expected, actual, correct, error|
        sample = dataset.samples.create!(
          input_data: { "description" => expected.to_s },
          expected_output: { "category_name" => expected },
          context_data: {},
          difficulty: "easy"
        )
        run.results.create!(
          sample: sample,
          actual_output: error ? { "error" => error } : { "category_name" => actual },
          correct: correct,
          exact_match: expected == actual,
          hierarchical_match: expected == actual,
          null_expected: expected.nil?,
          null_returned: actual.nil?,
          metadata: error ? { "error" => error } : {}
        )
      end

      run.complete!(Eval::Metrics::CategorizationMetrics.new(run).calculate)
      run
    end
end
