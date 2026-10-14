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

  Field = Data.define(:label, :value, :confidence) do
    def unsure? = confidence.present? && confidence < DocumentPanel::UNSURE_BELOW
  end

  Outcome = Data.define(:label, :url, :detail)

  # A validator result. `state` is true (passed), false (failed) or nil (not
  # checkable — the pipeline had nothing to run the check against). nil must
  # render as its own state, never as a pass.
  Check = Data.define(:label, :state)

  FIELD_LABELS = {
    "document_class" => "type", "institution_name" => "institution",
    "account_last4" => "account last4", "card_last4" => "card last4",
    "card_network" => "card network", "currency" => "currency",
    "total" => "total", "date" => "date", "payee" => "payee"
  }.freeze

  # The checks the pipeline ran, in the words a person reads. `nil` is "not
  # checkable" and must say so rather than render as a pass.
  CHECK_LABELS = {
    "totals_agree" => "OCR and AI agree on the total",
    "line_items_sum" => "the line items add up to the total",
    "last4_in_ocr" => "the card or account number was found in the page text",
    "date_parses" => "the date reads as a date"
  }.freeze

  # The statement-rows observations, kept out of CHECK_LABELS so neither appears
  # on a read that has nothing to do with them (a receipt). `checks` appends each
  # only when the read recorded it: the fallback check only when it actually
  # fired (rows were recovered from line_items), the date check whenever the
  # statement had rows — a date-less row (the fallback's carry none) reads as a
  # red flag, never a silent blank.
  STATEMENT_CHECK_LABELS = {
    "statement_rows_from_line_items" => "the statement rows were read from the line items field",
    "statement_rows_have_dates" => "every statement row has a date"
  }.freeze

  def initialize(link)
    @link = link
  end

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
    FIELD_LABELS.filter_map do |key, label|
      raw = verdict[key]
      next if raw.blank?

      Field.new(label: label, value: raw.to_s, confidence: confidence[key]&.to_f)
    end
  end

  def checks
    return [] unless extraction

    validations = extraction.validations.with_indifferent_access
    CHECK_LABELS.merge(statement_check_labels(validations))
                .map { |key, label| Check.new(label: label, state: validations[key]) }
  end

  # What the document became: the draft it was routed to, and the entry it
  # produced once it was published. This is the half that answers "and where did
  # that end up?".
  def outcomes
    [ draft_outcome, entry_outcome ].compact
  end

  private
    def routes = Rails.application.routes.url_helpers

    # The statement-rows checks to append, each only when the read recorded it
    # meaningfully — see STATEMENT_CHECK_LABELS.
    def statement_check_labels(validations)
      labels = {}
      if validations["statement_rows_from_line_items"]
        labels["statement_rows_from_line_items"] = STATEMENT_CHECK_LABELS["statement_rows_from_line_items"]
      end
      unless validations["statement_rows_have_dates"].nil?
        labels["statement_rows_have_dates"] = STATEMENT_CHECK_LABELS["statement_rows_have_dates"]
      end
      labels
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
