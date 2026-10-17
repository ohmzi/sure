# frozen_string_literal: true

# The filters a person has turned on, as the Documents redesign shows them
# (2026-10-16): one removable chip each, and their count on the filter
# button's badge. Search and type have their own controls on the page, and
# sort orders rather than narrows, so none of them is a chip. The "needs you"
# link (`attention`) is: the sheet has no control for it, so its chip is the
# only way to see it is on, and to take it off.
class DocumentBrowser::ActiveFilters
  Chip = Data.define(:label, :remove_url)

  # The keys that each make one chip per value, with the vocabulary a value
  # must belong to and how it reads.
  LISTS = {
    status: [ -> { DocumentLink::STATUSES }, ->(value) { I18n.t("documents.status.#{value}") } ],
    review: [ -> { AccountStatement::Search::REVIEW_FILTERS }, ->(value) { I18n.t("account_statements.status.#{value}") } ],
    extraction: [ -> { AccountStatement::Search::EXTRACTION_FILTERS }, ->(value) { I18n.t("document_browser.filters.extraction_states.#{value}") } ]
  }.freeze

  # Reset clears what the sheet holds (and the needs-you link and the order);
  # these two live on the page itself.
  KEPT_ON_RESET = %i[search type].freeze

  def initialize(filters:, url:, family:, currency:)
    @filters = filters.to_h.symbolize_keys
    @url = url
    @family = family
    @currency = currency
  end

  def chips
    @chips ||= [
      *list_chips(:status), *list_chips(:review), *list_chips(:extraction),
      *tag_chips, merchant_chip, amount_chip, date_chip, attention_chip
    ].compact
  end

  def count = chips.size

  def reset_url = url_for(@filters.slice(*KEPT_ON_RESET))

  # The type switch's links: the same filters with this type ("" is All).
  def type_url(type)
    url_for(@filters.merge(type: type.presence && [ type ]))
  end

  private
    def list_chips(key)
      vocabulary, label = LISTS.fetch(key)
      values(key).select { |value| vocabulary.call.include?(value) }.map do |value|
        Chip.new(label: label.call(value), remove_url: without_value(key, value))
      end
    end

    def tag_chips
      values(:tags).map { |tag| Chip.new(label: tag, remove_url: without_value(:tags, tag)) }
    end

    def merchant_chip
      merchant = @filters[:merchant].to_s.strip
      Chip.new(label: merchant, remove_url: without(:merchant)) if merchant.present?
    end

    def amount_chip
      min = money(@filters[:amount_min])
      max = money(@filters[:amount_max])
      label =
        if min && max then I18n.t("document_browser.filters.chips.amount_between", min: min, max: max)
        elsif min then I18n.t("document_browser.filters.chips.amount_over", amount: min)
        elsif max then I18n.t("document_browser.filters.chips.amount_under", amount: max)
        end
      Chip.new(label: label, remove_url: without(:amount_min, :amount_max)) if label
    end

    def date_chip
      from = date(@filters[:date_from])
      to = date(@filters[:date_to])
      label =
        if from && to then I18n.t("document_browser.filters.chips.date_between", from: short(from), to: short(to))
        elsif from then I18n.t("document_browser.filters.chips.date_from", date: short(from))
        elsif to then I18n.t("document_browser.filters.chips.date_to", date: short(to))
        end
      Chip.new(label: label, remove_url: without(:date_from, :date_to)) if label
    end

    def attention_chip
      return if @filters[:attention].blank?

      Chip.new(label: I18n.t("document_browser.filters.chips.needs_you"), remove_url: without(:attention))
    end

    def values(key) = Array(@filters[key]).map(&:to_s).reject(&:blank?)

    # The page's URL with whole keys taken out.
    def without(*keys) = url_for(@filters.except(*keys))

    # The page's URL with one value of a list taken out.
    def without_value(key, value) = url_for(@filters.merge(key => values(key) - [ value ]))

    def url_for(filters)
      kept = filters.reject { |_, value| Array(value).all?(&:blank?) }
      kept.empty? ? @url : "#{@url}?#{{ q: kept }.to_query}"
    end

    def money(value)
      amount = BigDecimal(value.to_s, exception: false)
      Money.new(amount, @currency).format if amount
    end

    def date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def short(date) = I18n.l(date, format: :short)
end
