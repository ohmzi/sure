# frozen_string_literal: true

# The read-only quality surface for automatic categorization.
#
# It reports the latest completed categorization evaluation (accuracy, how
# often the model abstained, and per-category accuracy) and the household's own
# correction signal from the category enrichment history.
#
# The correction figure is only a real signal because automatic writes leave a
# DataEnrichment row naming the value they wrote. A person's later edit does not
# write one, so an auto-sourced row that no longer matches the transaction's
# category means the automatic answer was changed. When no automatic assignment
# exists there is nothing to correct, and the rate is nil rather than a
# fabricated 0%.
class Eval::CategorizationQuality
  Category = Data.define(:name, :correct, :total, :accuracy)

  # Matches Transaction::AUTO_CATEGORY_SOURCES. A later rule write is still an
  # automatic answer, so the correction query checks every enrichment source
  # for the current value before calling a row corrected.
  AUTO_SOURCES = Transaction::AUTO_CATEGORY_SOURCES

  AUTO_ENRICHMENTS_JOIN = <<~SQL.squish
    INNER JOIN data_enrichments auto_enrichments
      ON auto_enrichments.enrichable_type = 'Transaction'
      AND auto_enrichments.enrichable_id = transactions.id
      AND auto_enrichments.attribute_name = 'category_id'
      AND auto_enrichments.source IN ('#{AUTO_SOURCES.join("','")}')
  SQL

  CORRECTED_SQL = <<~SQL.squish
    NOT EXISTS (
      SELECT 1
      FROM data_enrichments current_enrichments
      WHERE current_enrichments.enrichable_type = 'Transaction'
        AND current_enrichments.enrichable_id = transactions.id
        AND current_enrichments.attribute_name = 'category_id'
        AND current_enrichments.value = to_jsonb(transactions.category_id::text)
    )
  SQL

  def self.latest_completed_run
    Eval::Run
      .joins(:dataset)
      .where(status: "completed", eval_datasets: { eval_type: "categorization" })
      .order(Arel.sql("eval_runs.completed_at DESC NULLS LAST"), created_at: :desc)
      .first
  end

  attr_reader :family, :run

  def initialize(family:, run: self.class.latest_completed_run)
    @family = family
    @run = run
  end

  def present?
    run.present?
  end

  def accuracy
    value = metrics[:accuracy]
    value.nil? ? run.accuracy : value.to_f
  end

  def abstention_rate
    processed = samples_processed
    return 0.0 if processed.zero?

    (run.results.where(null_returned: true).count.to_f / processed * 100).round(2)
  end

  def samples_processed
    (metrics[:samples_processed].presence || run.results.count).to_i
  end

  def per_category
    stored = metrics[:by_category]
    rows = stored.present? ? stored.map { |name, values| category_row(name, values) } : calculated_per_category
    rows.sort_by { |row| [ -row.total, row.name ] }
  end

  # nil (rather than 0%) when the family has no automatic assignment to change,
  # so the view can omit the figure instead of inventing one.
  def correction_rate
    return nil if auto_categorized_count.zero?

    (corrected_count.to_f / auto_categorized_count * 100).round(2)
  end

  private
    def metrics
      @metrics ||= (run&.metrics || {}).with_indifferent_access
    end

    def category_row(name, values)
      total = values[:total].to_i
      correct = values[:correct].to_i
      Category.new(
        name: name,
        correct: correct,
        total: total,
        accuracy: values[:accuracy].presence&.to_f || (correct.to_f / total * 100).round(2)
      )
    end

    # A completed run stores by_category, but an older or hand-built run may
    # not; deriving it from the results keeps the surface useful without
    # trusting a metric that is absent.
    def calculated_per_category
      run.results.includes(:sample).each_with_object({}) do |result, rows|
        name = result.sample.expected_category_name || "null"
        row = rows[name] ||= { correct: 0, total: 0 }
        row[:total] += 1
        row[:correct] += 1 if result.correct
      end.map { |name, values| category_row(name, values) }
    end

    # Transactions this family ever assigned a category to automatically.
    # The enrichment join can match twice (one AI row and one Bayes row), so
    # every count is distinct.
    def auto_categorized_scope
      Transaction.family_scope(family).joins(AUTO_ENRICHMENTS_JOIN)
    end

    def auto_categorized_count
      @auto_categorized_count ||= auto_categorized_scope.distinct.count
    end

    def corrected_count
      @corrected_count ||= auto_categorized_scope.where(CORRECTED_SQL).distinct.count
    end
end
