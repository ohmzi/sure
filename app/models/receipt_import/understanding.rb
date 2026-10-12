# frozen_string_literal: true

# Adapts a DocumentUnderstanding to the three methods `apply_extraction!` has
# always consumed: complete?, date, to_extracted_data. Keeping that contract
# means the row builder, the understanding_state rules and the publish gate are
# untouched by the switch from a regex parser to a model — which is the point.
# The money path does not change; only what feeds it does.
class ReceiptImport::Understanding
  def initialize(understanding)
    @understanding = understanding
  end

  def complete? = @understanding.total.present?

  def date = @understanding.date

  def to_extracted_data
    {
      "total" => @understanding.total&.to_s("F"),
      "date" => @understanding.date&.iso8601,
      "payee" => @understanding.payee,
      "line_items" => @understanding.line_items.map do |item|
        { "description" => item["description"].to_s, "amount" => item["amount"].to_s }
      end
    }.compact
  end
end
