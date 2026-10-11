# frozen_string_literal: true

# What the extractor read from a receipt's OCR text. `total` is the only
# required fact: without it the draft is `needs_understanding` and the user
# enters it (M7: never a guess). Amounts are expense-positive — Sure's entry
# convention (§9.1) — matching ReceiptMatcher::Extraction's documented rule, so
# this draft's `inflows_negative` signage is the identity in signed_amount.
class ReceiptImport::Extraction
  LineItem = Data.define(:description, :amount)

  attr_reader :total, :date, :payee, :line_items

  def initialize(total: nil, date: nil, payee: nil, line_items: [])
    @total = total
    @date = date
    @payee = payee
    @line_items = line_items
  end

  def complete?
    total.present?
  end

  def to_extracted_data
    {
      "total" => total&.to_s("F"),
      "date" => date&.iso8601,
      "payee" => payee,
      "line_items" => line_items.map { |i| { "description" => i.description, "amount" => i.amount.to_s("F") } }
    }.compact
  end
end
