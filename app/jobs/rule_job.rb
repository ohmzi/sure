# Applies a single rule ("Apply rule" in the UI). The active rules above it run
# first, so the result is the same as in the full run (see Rule::Runner).
class RuleJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  def perform(rule, ignore_attribute_locks: false, execution_type: "manual", actor: nil, batch_id: nil)
    runner = Rule::Runner.new(
      rule.family,
      rules: [ rule ],
      execution_type: execution_type,
      ignore_attribute_locks: ignore_attribute_locks,
      application_batch_id: batch_id,
      actor: actor
    )
    rule_runs = runner.run

    # The RuleRun records the failure; re-raise so the job is marked failed.
    # A failing rule above is only recorded, because a retry would re-run all
    # rules above as well. The applied rule runs last, so its error is last.
    raise runner.errors.last if rule_runs.last&.status == "failed"
  end
end
