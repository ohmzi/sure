require "test_helper"

class Eval::CategorizationQualityTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  def create_run(eval_type: "categorization", status: "completed", completed_at: Time.current,
                 model: "test-model", family: @family)
    dataset = Eval::Dataset.create!(
      name: "quality_#{SecureRandom.hex(4)}",
      eval_type: eval_type,
      version: "1.0",
      metadata: family ? { "family_id" => family.id } : {}
    )
    Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: model,
      status: status,
      completed_at: completed_at
    )
  end

  def add_result(run, expected:, actual:, correct:, null_expected: false, null_returned: false, error: nil)
    sample = run.dataset.samples.create!(
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
      null_expected: null_expected,
      null_returned: null_returned,
      metadata: error ? { "error" => error } : {}
    )
  end

  def complete!(run)
    run.complete!(Eval::Metrics::CategorizationMetrics.new(run).calculate)
    run
  end

  test "reports no run before the first completed categorization evaluation for the family" do
    quality = Eval::CategorizationQuality.new(family: @family)

    assert_not quality.present?
    assert_nil quality.run
  end

  test "uses the latest completed categorization run for the family" do
    old = complete!(create_run(completed_at: 2.days.ago))
    latest = complete!(create_run(completed_at: 1.hour.ago))

    # A later run is not this household's result when it belongs to another
    # family, to a synthetic dataset with no family, or is not a completed
    # categorization evaluation at all.
    create_run(completed_at: 30.minutes.ago, family: families(:empty))
    create_run(completed_at: 20.minutes.ago, family: nil)
    create_run(status: "running", completed_at: nil)
    create_run(status: "failed", completed_at: 10.minutes.ago)
    create_run(eval_type: "merchant_detection", completed_at: 5.minutes.ago)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_equal latest.id, quality.run.id
    assert_not_equal old.id, quality.run.id
  end

  test "reports accuracy, abstention rate and per-category accuracy" do
    run = create_run
    add_result(run, expected: "Food & Drink", actual: "Food & Drink", correct: true)
    add_result(run, expected: "Food & Drink", actual: "Income", correct: false)
    add_result(run, expected: "Income", actual: "Income", correct: true)
    add_result(run, expected: nil, actual: nil, correct: true, null_expected: true, null_returned: true)
    complete!(run)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_equal 75.0, quality.accuracy
    assert_equal 25.0, quality.abstention_rate
    assert_equal 4, quality.samples_processed
    assert_not quality.errored?

    by_category = quality.per_category.index_by(&:name)
    assert_equal 50.0, by_category["Food & Drink"].accuracy
    assert_equal 2, by_category["Food & Drink"].total
    assert_equal 100.0, by_category["Income"].accuracy
    assert_equal 100.0, by_category["null"].accuracy
  end

  test "calculates per-category accuracy from results when the stored metrics lack it" do
    run = create_run
    add_result(run, expected: "Food & Drink", actual: "Food & Drink", correct: true)
    add_result(run, expected: "Food & Drink", actual: "Income", correct: false)

    quality = Eval::CategorizationQuality.new(family: @family)

    row = quality.per_category.find { |category| category.name == "Food & Drink" }
    assert_equal 1, row.correct
    assert_equal 2, row.total
    assert_equal 50.0, row.accuracy
  end

  test "memoizes per-category accuracy" do
    run = create_run
    add_result(run, expected: "Food & Drink", actual: "Food & Drink", correct: true)
    complete!(run)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_same quality.per_category, quality.per_category
  end

  test "suppresses accuracy and excludes errored samples from abstention" do
    run = create_run
    add_result(run, expected: "Food & Drink", actual: "Food & Drink", correct: true)
    add_result(run, expected: nil, actual: nil, correct: true, null_expected: true, null_returned: true)
    add_result(run, expected: "Food & Drink", actual: nil, correct: false, null_returned: true, error: "provider outage")
    complete!(run)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_nil quality.accuracy, "a run with errored samples does not state a model accuracy"
    assert quality.errored?
    assert_equal 1, quality.samples_errored
    assert_equal 3, quality.total_results
    assert_equal 2, quality.samples_processed
    assert_equal 50.0, quality.abstention_rate, "the errored sample's null_returned is not an abstention"

    food = quality.per_category.find { |category| category.name == "Food & Drink" }
    assert_equal 1, food.total, "per-category accuracy also excludes errored samples"
  end

  test "treats a completed run with no usable results as the empty state" do
    run = create_run
    add_result(run, expected: "Food & Drink", actual: nil, correct: false, null_returned: true, error: "provider outage")
    complete!(run)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_not quality.present?
    assert_equal 0, quality.samples_processed
  end

  test "treats a completed run with no results as the empty state" do
    run = create_run
    complete!(run)

    assert_not Eval::CategorizationQuality.new(family: @family).present?
  end

  test "does not expose a correction rate" do
    run = create_run
    add_result(run, expected: "Food & Drink", actual: "Food & Drink", correct: true)
    complete!(run)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_not_respond_to quality, :correction_rate
  end
end
