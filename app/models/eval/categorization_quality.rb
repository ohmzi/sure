# frozen_string_literal: true

# The read-only quality surface for a household's automatic categorization.
#
# It reports the latest completed categorization evaluation that belongs to the
# family (the export task stamps the family id into the dataset metadata), plus
# how often the model abstained and its per-category accuracy.
#
# Eval datasets and runs are global, so the family scope is applied on every
# read: another household's run — or an unowned golden/synthetic dataset — is
# never a valid result for this page.
#
# A provider outage records each sample as incorrect with an error in the
# result metadata. Those samples say nothing about the model, so they are
# excluded from abstention and per-category figures, the accuracy figure is
# suppressed, and a run with no usable sample is treated as no result at all.
class Eval::CategorizationQuality
  Category = Data.define(:name, :correct, :total, :accuracy)

  def self.latest_completed_run(family)
    Eval::Run
      .joins(:dataset)
      .where(status: "completed", eval_datasets: { eval_type: "categorization" })
      .where("eval_datasets.metadata->>'family_id' = ?", family.id.to_s)
      .order(Arel.sql("eval_runs.completed_at DESC NULLS LAST"), created_at: :desc)
      .first
  end

  attr_reader :family, :run

  def initialize(family:, run: nil)
    @family = family
    @run = run || self.class.latest_completed_run(family)
  end

  # A completed run with no usable result is not a quality result: rendering 0%
  # accuracy from an empty or entirely-errored run would state a model
  # performance that was never measured.
  def present?
    run.present? && usable_results_count.positive?
  end

  # nil when the run had errors: its stored accuracy counts errored samples as
  # wrong answers, which is not a model measurement. The view renders this as
  # "Not reported" and names the error count.
  def accuracy
    return nil if errored?

    metrics[:accuracy]&.to_f || run.accuracy
  end

  # Over usable (non-errored) samples only, so a provider outage does not read
  # as 100% abstention.
  def abstention_rate
    return nil if usable_results_count.zero?

    (abstained_count.to_f / usable_results_count * 100).round(2)
  end

  def samples_processed
    usable_results_count
  end

  def samples_errored
    return 0 unless run

    @samples_errored ||= run.results.where("metadata->>'error' IS NOT NULL").count
  end

  def total_results
    return 0 unless run

    @total_results ||= run.results.count
  end

  def errored?
    samples_errored.positive?
  end

  def per_category
    @per_category ||= begin
      rows = if errored? || metrics[:by_category].blank?
        calculated_per_category
      else
        metrics[:by_category].map { |name, values| category_row(name, values) }
      end

      rows.sort_by { |row| [ -row.total, row.name ] }
    end
  end

  private
    def metrics
      @metrics ||= (run&.metrics || {}).with_indifferent_access
    end

    def usable_results_count
      @usable_results_count ||= total_results - samples_errored
    end

    def abstained_count
      @abstained_count ||= run.results
                              .where("metadata->>'error' IS NULL")
                              .where(null_returned: true)
                              .count
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
    # not, and a run with errors needs the errored samples removed from its
    # per-category figures.
    def calculated_per_category
      run.results
         .where("metadata->>'error' IS NULL")
         .includes(:sample)
         .each_with_object({}) do |result, rows|
           name = result.sample.expected_category_name || "null"
           row = rows[name] ||= { correct: 0, total: 0 }
           row[:total] += 1
           row[:correct] += 1 if result.correct
         end.map { |name, values| category_row(name, values) }
    end
end
