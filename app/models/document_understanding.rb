# frozen_string_literal: true

# The AI's verdict on one document, as a typed view over the stored JSON.
#
# Every reader is defensive on purpose: a model returns validly-typed nonsense
# routinely, and a raised Date::Error deep inside a job is a wedged document.
# An unreadable field reads as nil, and nil is what the validators (Task 7) and
# the classifier (Task 6) act on — never a guess.
class DocumentUnderstanding
  CLASSES = DocumentLink::SOURCES

  # Well-formed grouping only: "1,234.56" is fine, but misplaced commas such as
  # "12,34,5" are unreadable nonsense and must read as nil, never as a guess
  # like 12345. The ONE definition of "a parseable amount" — `total` and the
  # job's `line_items_sum` check both go through `parse_amount`, so neither can
  # drift back into accepting a value the other rejects. A false pass on that
  # sum gates Milestone B's auto-post, where a wrong `true` is money.
  AMOUNT_PATTERN = /\A-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?\z/

  attr_reader :verdict

  # The guarded amount parse. nil means unparseable, everywhere.
  def self.parse_amount(value)
    text = value.to_s.strip
    return nil unless text.match?(AMOUNT_PATTERN)

    BigDecimal(text.delete(","))
  rescue ArgumentError
    nil
  end

  def initialize(verdict)
    @verdict = (verdict || {}).with_indifferent_access
  end

  def document_class
    candidate = verdict[:document_class].presence&.to_s
    CLASSES.include?(candidate) ? candidate : nil
  end

  def institution_name = verdict[:institution_name].presence&.to_s
  def account_last4 = digits(verdict[:account_last4], 4)
  def card_last4 = digits(verdict[:card_last4], 4)
  def card_network = Account::CARD_NETWORKS.include?(verdict[:card_network].to_s) ? verdict[:card_network].to_s : nil
  def currency = verdict[:currency].presence&.to_s&.upcase
  def payee = verdict[:payee].presence&.to_s
  def field_confidence = (verdict[:field_confidence] || {}).with_indifferent_access

  def total
    self.class.parse_amount(verdict[:total])
  end

  def date
    raw = verdict[:date].presence or return nil
    Date.parse(raw.to_s)
  rescue Date::Error
    nil
  end

  def period_start = parse_date(statement_period_field(:start))
  def period_end = parse_date(statement_period_field(:end))

  def line_items = member_hashes(verdict[:line_items])

  # Statements carry rows; a receipt carries line items. Keeping them separate
  # means neither can be mistaken for the other downstream. The gate is the
  # DOCUMENT's class, because a batch is not a document: on the generic no-schema
  # read a mid-statement run of continuation pages routinely comes back
  # classified "other", and gating on that batch's own class silently dropped its
  # rows. The batched read therefore accumulates `transaction_rows` (raw, ungated)
  # and this reader — keyed on the merged verdict's class, the same one
  # DocumentClassifier judges — decides whether they are the document's rows.
  #
  # When a statement carries no `transactions` but the model filed the rows under
  # `line_items`, those entries ARE the statement's rows: the local vision model
  # (qwen2.5vl:7b) reads a statement's table correctly but its field choice varies
  # run to run, and the app's statement path consumes only `transactions`, so the
  # rows would otherwise be silently discarded. They are adopted here (flagged by
  # `statement_rows_from_line_items?`) rather than dropped.
  def transactions
    return [] unless document_class == "statement"
    return transaction_rows if transaction_rows.any?

    rows_from_line_items
  end

  # Whether the statement's rows came from the `line_items` field because
  # `transactions` was empty. The job records this on the read so the fallback is
  # visible, never silent.
  def statement_rows_from_line_items?
    document_class == "statement" && transaction_rows.empty? && line_items.any?
  end

  # The rows as the model sent them, with no class gate and the same coercion as
  # `transactions` (so neither reader can hand a non-hash member downstream).
  def transaction_rows
    member_hashes(verdict[:transactions])
  end

  def to_verdict = verdict.to_h.deep_stringify_keys

  # A copy carrying the given transactions. The read is batched by page, so the
  # statement's rows accumulate across several verdicts while its identity
  # fields come from the first batch that reported them; the class has no
  # writer, so the stitched read is assembled into a new one.
  def with_transactions(rows)
    self.class.new(verdict.merge("transactions" => rows))
  end

  # The same, for the line items a multi-page receipt carries beyond its first
  # page — batching is not the statement leg's alone, and merge_understanding
  # keeps only the first value it sees for every other field.
  def with_line_items(rows)
    self.class.new(verdict.merge("line_items" => rows))
  end

  def confidence_for(field) = field_confidence[field].to_f

  private
    def digits(value, length)
      text = value.to_s.gsub(/\D/, "")
      text.length == length ? text : nil
    end

    def parse_date(value)
      Date.parse(value.to_s) if value.present?
    rescue Date::Error
      nil
    end

    # statement_period is unconstrained on the generic path (no schema is sent):
    # the model may return a bare string, so dig would raise TypeError. Guard to
    # a hash and read the key, or nil.
    def statement_period_field(key)
      period = verdict[:statement_period]
      period.is_a?(Hash) ? period[key] : nil
    end

    # Coerce an untrusted array slot into indifferent-access hashes, dropping any
    # member the model sent as a non-hash (a String, number, nested array…) so
    # that mapping cannot raise NoMethodError.
    def member_hashes(value)
      Array(value)
        .select { |i| i.respond_to?(:with_indifferent_access) }
        .map { |i| i.with_indifferent_access }
    end

    # A line item reshaped into a statement row: its description is the row's
    # name, its amount is kept verbatim, and `source_page` (when the batch that
    # read it covered one page) rides along so the row keeps its page anchor. No
    # date is invented — a line item carries none, so the row's date is left
    # unknown and the read flags it.
    def rows_from_line_items
      line_items.map do |item|
        row = { "name" => item["description"].to_s, "amount" => item["amount"].to_s, "notes" => nil }
        row["source_page"] = item["source_page"] if item.key?("source_page")
        row
      end
    end
end
