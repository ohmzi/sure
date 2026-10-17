# frozen_string_literal: true

# The per-document "what I understood" view (spec §9): the read, its doubts, and
# what it produced. A view-model, not a query — everything here is already on the
# link and its latest extraction, which is the whole reason the pipeline stores
# an extraction row rather than throwing the verdict away.
#
# Two readers decide the viewer's shape: `split?` (there is a read worth showing,
# so the lightbox becomes a document-left / panel-right split) and `shows_panel?`
# (there is anything to say at all — a read with fields, an unread document that
# owes the reader a reason, or a read still in flight). A read that produced no
# fields is the one case that stays a picture.
class DocumentPanel
  # Below this, a field is a doubt and renders as "check this" rather than as a
  # plain fact. The design's per-field confidence gate; there is no global one.
  UNSURE_BELOW = 0.6

  # `key` is the verdict key the field was built from (`document_class`, `total`,
  # `payee`, …): the view filters and keys off it, not off the (translatable)
  # label, so the "hide the class row" branch and the `data-field` selectors stay
  # stable when a label is translated.
  Field = Data.define(:key, :label, :value, :confidence) do
    def unsure? = confidence.present? && confidence < DocumentPanel::UNSURE_BELOW
  end

  Outcome = Data.define(:label, :url, :detail)

  # A validator result. `state` is true (passed), false (failed) or nil (not
  # checkable — the pipeline had nothing to run the check against). nil must
  # render as its own state, never as a pass.
  Check = Data.define(:label, :state)

  # One reader the read tried (spec §6): who, what happened, how long.
  Attempt = Data.define(:reader, :outcome, :duration)

  # The verdict keys the panel shows as fields, each mapped to the locale key its
  # label resolves through (`fields` calls I18n.t on it), under
  # documents.understanding.field_labels. Same shape and convention as the check
  # labels below.
  FIELD_LABEL_KEYS = {
    "document_class" => "documents.understanding.field_labels.document_class",
    "institution_name" => "documents.understanding.field_labels.institution_name",
    "account_last4" => "documents.understanding.field_labels.account_last4",
    "card_last4" => "documents.understanding.field_labels.card_last4",
    "card_network" => "documents.understanding.field_labels.card_network",
    "currency" => "documents.understanding.field_labels.currency",
    "total" => "documents.understanding.field_labels.total",
    "date" => "documents.understanding.field_labels.date",
    "payee" => "documents.understanding.field_labels.payee"
  }.freeze

  # The checks the pipeline ran, in the words a person reads. `nil` is "not
  # checkable" and must say so rather than render as a pass. Each value is a
  # locale key: `checks` resolves it through I18n, so the label a viewer sees is
  # the one their locale asks for (documents.understanding.check_labels.*).
  CHECK_LABEL_KEYS = {
    "totals_agree" => "documents.understanding.check_labels.totals_agree",
    "line_items_sum" => "documents.understanding.check_labels.line_items_sum",
    "last4_in_ocr" => "documents.understanding.check_labels.last4_in_ocr",
    "date_parses" => "documents.understanding.check_labels.date_parses"
  }.freeze

  # The statement-rows observations, kept out of CHECK_LABEL_KEYS so neither
  # appears on a read that has nothing to do with them (a receipt). `checks`
  # appends each only when the read recorded it: the fallback check only when it
  # actually fired (rows were recovered from line_items), the date check whenever
  # the statement had rows — a date-less row (the fallback's carry none) reads as
  # a red flag, never a silent blank. Values are locale keys, as above.
  STATEMENT_CHECK_LABEL_KEYS = {
    "statement_rows_from_line_items" => "documents.understanding.check_labels.statement_rows_from_line_items",
    "statement_rows_have_dates" => "documents.understanding.check_labels.statement_rows_have_dates",
    "statement_totals_reconcile" => "documents.understanding.check_labels.statement_totals_reconcile",
    "statement_rows_missing_dates" => "documents.understanding.check_labels.statement_rows_missing_dates",
    "statement_row_count" => "documents.understanding.check_labels.statement_row_count",
    "statement_rows_signs_verified" => "documents.understanding.check_labels.statement_rows_signs_verified"
  }.freeze

  # A model read's rows are oriented to the reader's signs; only these two
  # orientations were PROVEN by the statement's totals (the others were guessed).
  VERIFIED_ORIENTATIONS = %w[as_read flipped].freeze

  # R-W8B13: the reader's source is PROVENANCE, not a pass/fail. Rendering a
  # scan's `vision` source red would flag every legitimate scan, and a read that
  # reached the panel has by definition passed the gate — so the source shows a
  # label that NAMES it (never red), and the CHECKS carry the red
  # (`statement_totals_reconcile` failing is the mismatch rendering red).
  SOURCE_LABEL_KEYS = {
    "text_layer" => "documents.understanding.source_labels.text_layer",
    "geometry" => "documents.understanding.source_labels.geometry",
    "vision" => "documents.understanding.source_labels.vision"
  }.freeze
  SOURCE_FALLBACK_LABEL_KEY = "documents.understanding.source_labels.fallback".freeze

  attr_reader :link

  def initialize(link)
    @link = link
  end

  # Why the document is held, with its actions — nil when it is not.
  def hold = @link.hold_reason

  # Memoized on purpose. `DocumentLink#extraction` is an un-memoized
  # `order(...).first`, and one viewer render reads it through several readers
  # (`shows_panel?` -> `read?`/`fields` -> `split?` -> ...): without this, every
  # reader fired its own SELECT. The panel is built once per request and the
  # link's reads cannot change mid-render, so caching the latest read here is
  # correct. `defined?` (not `||=`) so a link with no read caches the nil too.
  def extraction
    return @extraction if defined?(@extraction)

    @extraction = @link.extraction
  end

  def read? = extraction.present? && extraction.status == "succeeded"

  # The read is in flight: the row is queued or processing with nothing held, and
  # no read has landed yet (or a `pending` row has). This is NOT "unread" — the
  # document is being read — and it must not be told to configure a provider it
  # is already using. It is the state the tile shows as "Reading…".
  def reading? = @link.failure_message.blank? &&
                 (extraction.nil? ? @link.status.in?(%w[queued processing]) : extraction.status == "pending")

  # The design's rule: a picture stays a picture; a document with something to
  # say opens split, because a read the user cannot see is the problem itself.
  def split? = read? && fields.any?

  # Whether the viewer has anything to say at all. A read with fields splits; a
  # document with no read still owes the reader the reason and the two ways
  # forward. Only a read that produced no fields stays a plain picture.
  def shows_panel? = split? || !read?

  # The class the router settled on (the extraction holds the model's proposal;
  # this is the corroborated one) and how sure it was, for the panel's header.
  def document_class = @link.source
  def classification_confidence = @link.classification_confidence

  # The account the read resolved to, if any — the draft's for a receipt or
  # bill, the statement's for a statement. nil is a real answer ("Which
  # account?" on the tile, "No account yet" in the panel), never a silent gap.
  def account = draft&.account || @link.account_statement&.account

  def empty_reason
    # A read in flight is not a document that failed to be read: it says it is
    # being read, and never that a provider needs configuring.
    return I18n.t("documents.understanding.reading_reason") if reading?

    if extraction
      # A read that ran and did not succeed: its own stated reason, else the
      # status itself (pending / failed).
      return extraction.error.presence || I18n.t("documents.understanding.#{extraction.status}")
    end

    # No read at all. The reason the read was held lives on the link (the live
    # host's "no AI provider is configured"); with nothing held, it simply has
    # not run yet.
    @link.failure_message.presence || I18n.t("documents.understanding.not_read_yet")
  end

  def fields
    return [] unless extraction

    verdict = extraction.verdict.with_indifferent_access
    confidence = extraction.field_confidence.with_indifferent_access
    FIELD_LABEL_KEYS.filter_map do |key, label_key|
      raw = verdict[key]
      next if raw.blank?

      Field.new(key: key, label: I18n.t(label_key), value: raw.to_s, confidence: confidence[key]&.to_f)
    end
  end

  def checks
    return [] unless extraction

    validations = extraction.validations.with_indifferent_access
    CHECK_LABEL_KEYS.merge(statement_check_label_keys(validations))
                    .map { |key, label_key| Check.new(label: I18n.t(label_key), state: check_state(key, validations)) }
  end

  # Every reader the read tried, in order — the history behind a read that
  # worked after a fallback, and behind a hold.
  def attempts
    return [] unless extraction

    Array(extraction.validations["read_attempts"]).map do |attempt|
      seconds = attempt["seconds"].to_f
      Attempt.new(
        reader: attempt["reader"].to_s.upcase_first,
        outcome: I18n.t("documents.understanding.attempt_outcomes.#{attempt['outcome']}",
                        default: attempt["outcome"].to_s.humanize),
        duration: (I18n.t("documents.understanding.attempt_seconds", count: seconds.round) if seconds.positive?)
      )
    end
  end

  # What the document became: the draft it was routed to, and the entry it
  # produced once it was published. This is the half that answers "and where did
  # that end up?".
  def outcomes
    [ draft_outcome, entry_outcome ].compact
  end

  # Every document in this statement's duplicate group, including this one.
  # Rendered by the viewer/show so a person can compare the copies, delete an
  # extra, or open the statement page and correct its account/period.
  def duplicates = @link.duplicate_group

  private
    def routes = Rails.application.routes.url_helpers

    # The statement-rows checks to append, each only when the read recorded it
    # meaningfully — see STATEMENT_CHECK_LABEL_KEYS.
    def statement_check_label_keys(validations)
      labels = {}
      if validations["statement_rows_from_line_items"]
        labels["statement_rows_from_line_items"] = STATEMENT_CHECK_LABEL_KEYS["statement_rows_from_line_items"]
      end
      # R-W8B10 / the duplicate date check: on the reader path the reader's OWN
      # date audit (`statement_rows_missing_dates`, correct polarity) is
      # authoritative, so the wave-6 `statement_rows_have_dates` — the same fact
      # stated twice over the same routed rows — is not shown beside it. On the
      # model-fallback path the reader key is absent, and
      # `statement_rows_have_dates` remains the only date check. A correct read
      # therefore shows exactly ONE date check, and never a red one.
      if validations["statement_rows_missing_dates"].nil?
        unless validations["statement_rows_have_dates"].nil?
          labels["statement_rows_have_dates"] = STATEMENT_CHECK_LABEL_KEYS["statement_rows_have_dates"]
        end
      else
        labels["statement_rows_missing_dates"] = STATEMENT_CHECK_LABEL_KEYS["statement_rows_missing_dates"]
      end
      unless validations["statement_totals_reconcile"].nil?
        labels["statement_totals_reconcile"] = STATEMENT_CHECK_LABEL_KEYS["statement_totals_reconcile"]
      end
      unless validations["statement_row_count"].nil?
        labels["statement_row_count"] = STATEMENT_CHECK_LABEL_KEYS["statement_row_count"]
      end
      if validations["statement_rows_orientation"].present?
        labels["statement_rows_signs_verified"] = STATEMENT_CHECK_LABEL_KEYS["statement_rows_signs_verified"]
      end
      if validations["statement_rows_source"].present?
        labels["statement_rows_source"] =
          SOURCE_LABEL_KEYS.fetch(validations["statement_rows_source"].to_s, SOURCE_FALLBACK_LABEL_KEY)
      end
      labels
    end

    # The state of one check. Most are stored directly (a boolean or nil); the
    # wave-8 keys carry richer values, so their state is derived here: the source
    # is PROVENANCE and never red for a gate-passed read (R-W8B13), and a row
    # count only passes when the reader actually found rows — 0 is a red on a
    # held, empty read, never a raw value passed through (R-W8B10).
    def check_state(key, validations)
      case key
      when "statement_rows_signs_verified"
        VERIFIED_ORIENTATIONS.include?(validations["statement_rows_orientation"].to_s)
      when "statement_rows_source"
        validations[key].present? ? true : nil
      when "statement_row_count"
        value = validations[key]
        value.nil? ? nil : value.to_i.positive?
      else
        validations[key]
      end
    end

    def draft = @draft ||= @link.receipt_imports.max_by(&:created_at)

    # Both outcomes carry their link: the traceability ("which document did this
    # come from", spec §9's "each linked") is why the milestone exists, so the
    # panel must not stop one click short of the thing it produced.
    def draft_outcome
      return nil unless draft

      Outcome.new(label: I18n.t("documents.understanding.draft"),
                  url: routes.import_path(draft), detail: draft.understanding_state)
    end

    def entry_outcome
      entry = @link.entry
      return nil unless entry

      # `transaction_path`, as the controller's own `link` action redirects the
      # same edge today (`redirect_to transaction_path(entry)`).
      Outcome.new(label: I18n.t("documents.understanding.entry"),
                  url: routes.transaction_path(entry), detail: entry.name)
    end
end
