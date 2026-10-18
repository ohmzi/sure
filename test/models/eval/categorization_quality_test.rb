require "test_helper"

class Eval::CategorizationQualityTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  def create_run(eval_type: "categorization", status: "completed", completed_at: Time.current, model: "test-model")
    dataset = Eval::Dataset.create!(
      name: "quality_#{SecureRandom.hex(4)}",
      eval_type: eval_type,
      version: "1.0"
    )
    Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: model,
      status: status,
      completed_at: completed_at
    )
  end

  def add_result(run, expected:, actual:, correct:, null_expected: false, null_returned: false)
    sample = run.dataset.samples.create!(
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
      null_expected: null_expected,
      null_returned: null_returned
    )
  end

  def complete!(run)
    run.complete!(Eval::Metrics::CategorizationMetrics.new(run).calculate)
    run
  end

  test "reports no run before the first completed categorization evaluation" do
    quality = Eval::CategorizationQuality.new(family: @family)

    assert_not quality.present?
    assert_nil quality.run
  end

  test "uses the latest completed categorization run" do
    old = complete!(create_run(completed_at: 2.days.ago))
    latest = complete!(create_run(completed_at: 1.hour.ago))

    # A later run that is not a completed categorization evaluation is not a
    # quality result: a pending run, a failed run, or another eval type.
    create_run(status: "running", completed_at: nil)
    create_run(status: "failed", completed_at: 30.minutes.ago)
    create_run(eval_type: "merchant_detection", completed_at: 10.minutes.ago)

    assert_equal latest.id, Eval::CategorizationQuality.new(family: @family).run.id
    assert_not_equal old.id, Eval::CategorizationQuality.new(family: @family).run.id
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

  test "measures corrections from automatic category enrichment that no longer matches" do
    food = categories(:food_and_drink)
    income = categories(:income)

    # An AI assignment the person left alone: automatic, not a correction.
    # Start uncategorized so the enrichment is a real write (enriching to the
    # value already on the fixture would be a no-op and log nothing).
    kept = transactions(:transaction_entry)
    kept.update!(category_id: nil)
    kept.enrich_attribute(:category_id, food.id, source: "ai")

    # An AI assignment the person replaced with a different category. The
    # enrichment still names the old value, which is the correction signal the
    # provenance helper reads.
    corrected = transactions(:depository_transaction)
    corrected.enrich_attribute(:category_id, income.id, source: "ai")
    corrected.update!(category_id: food.id)

    quality = Eval::CategorizationQuality.new(family: @family)

    assert_equal 50.0, quality.correction_rate
  end

  test "omits the correction rate when nothing was categorized automatically" do
    transactions(:transaction_entry).update!(category_id: categories(:food_and_drink).id)

    assert_nil Eval::CategorizationQuality.new(family: @family).correction_rate
  end

  test "scopes the correction signal to the family" do
    food = categories(:food_and_drink)
    income = categories(:income)

    ours = transactions(:transaction_entry)
    ours.enrich_attribute(:category_id, income.id, source: "ai")
    ours.update!(category_id: food.id)

    other_family = families(:empty)
    other_account = Account.create!(
      family: other_family,
      name: "Someone else's account",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "USD",
      status: "active"
    )
    other_entry = other_account.entries.create!(
      name: "Someone else's transaction",
      date: Date.current,
      amount: 10,
      currency: "USD",
      entryable: Transaction.new
    )
    theirs = other_entry.transaction
    theirs.enrich_attribute(:category_id, income.id, source: "ai")
    theirs.update!(category_id: food.id)

    assert_equal 100.0, Eval::CategorizationQuality.new(family: @family).correction_rate
  end
end
