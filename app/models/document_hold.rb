# frozen_string_literal: true

# Why a document stopped, in a form the archive can act on (spec §6): the step
# that stopped, a code, the plain sentence the owner reads, and the buttons that
# fix it. Stored on the read's DocumentExtraction (`validations["hold"]`); the
# sentence is also the link's `failure_message`.
#
# A ladder failure is described reader by reader from the read's attempts, with
# the provider's raw error kept in the log — the sentence says "DeepSeek is
# overloaded right now", never "status 503".
DocumentHold = Data.define(:step, :code, :message, :actions) do
  # The holds the job raises outside the reader ladder, their step and the
  # actions that can help. `retry` re-runs the whole read.
  NAMED = {
    "statement_drift" => { step: "check", actions: %w[retry_online] },
    "statement_permission" => { step: "account", actions: [] },
    "ocr_unreadable" => { step: "ocr", actions: %w[retry] },
    "ocr_not_configured" => { step: "ocr", actions: %w[open_settings] },
    "read_error" => { step: "read", actions: %w[retry] },
    "file_missing" => { step: "read", actions: %w[retry] },
    "statement_duplicate" => { step: "check", actions: %w[delete] }
  }.freeze

  READER_ACTIONS = { "retry_local" => "local", "retry_online" => "online" }.freeze

  # A failure the system can retry by itself: the GPU was busy, the provider
  # was unreachable/overloaded, or the read hit an unexpected-but-transient
  # error. These rows stay sweepable and re-enqueue on a backoff.
  self::OCR_RETRYABLE_CODES = %w[ocr_unreachable ocr_server_error ocr_bad_response].freeze
  self::RETRYABLE_CODES = (self::OCR_RETRYABLE_CODES + %w[all_readers_failed gpu_busy read_error]).freeze

  # A failure only a person or a configuration change can fix: the file cannot
  # be read, OCR or a reader is not configured, the household lacks permission,
  # the month is a duplicate, or the deterministic check drifted. These are not
  # re-enqueued; the archive offers Retry instead.
  self::TERMINAL_CODES = %w[
    ocr_unreadable ocr_not_configured no_reader_configured file_missing
    statement_permission statement_duplicate statement_drift retry_exhausted
  ].freeze

  def retryable? = self.class::RETRYABLE_CODES.include?(code)

  def self.named(code, message:)
    spec = NAMED.fetch(code)
    new(step: spec[:step], code: code, message: message, actions: available(spec[:actions]))
  end

  # The hold for a read no reader finished, from its attempts.
  def self.for_attempts(attempts)
    actions = available(READER_ACTIONS.keys)
    if attempts.empty?
      return new(step: "read", code: "no_reader_configured", message: I18n.t("document_holds.no_reader_configured"),
                 actions: actions.presence || %w[open_settings])
    end

    outcomes = attempts.map { |attempt| attempt["outcome"] }
    code = outcomes.uniq == [ "skipped_busy" ] ? "gpu_busy" : "all_readers_failed"
    parts = attempts.map { |attempt| describe(attempt) }
    message = I18n.t("document_holds.ladder", attempts: parts.join("; ").upcase_first)
    new(step: "read", code: code, message: message, actions: actions.presence || %w[open_settings])
  end

  def self.from_h(hash)
    data = hash.to_h.stringify_keys
    new(step: data["step"], code: data["code"], message: data["message"], actions: Array(data["actions"]))
  end

  # An action is offered only when something stands behind it: no "Retry with
  # online AI" without a cloud key.
  def self.available(actions)
    actions.select do |action|
      mode = READER_ACTIONS[action]
      mode.nil? || DocumentReaderLadder.for(mode: mode).any?
    end
  end

  def self.describe(attempt)
    reader = attempt["reader"]
    case attempt["outcome"]
    when "skipped_busy" then I18n.t("document_holds.attempts.skipped_busy", reader: reader)
    when "timed_out" then I18n.t("document_holds.attempts.timed_out", reader: reader)
    when "did_not_add_up" then I18n.t("document_holds.attempts.did_not_add_up", reader: reader)
    else I18n.t("document_holds.attempts.failed.#{failure_kind(attempt['detail'])}", reader: reader)
    end
  end

  # The provider's HTTP status, read from its error text, decides the words.
  def self.failure_kind(detail)
    case detail.to_s[/status (\d{3})/, 1]
    when "503", "502", "504", "500" then "unavailable"
    when "429" then "quota"
    when "401", "403" then "key"
    else "other"
    end
  end

  private_class_method :available, :describe, :failure_kind
end
