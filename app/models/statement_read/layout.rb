# frozen_string_literal: true

class StatementRead
  # The bank-specific statement layouts. A layout that recognises a statement's
  # text reads it whole — identity, totals, rows and its own checks — and
  # returns a StatementRead::Result. A statement no layout recognises takes the
  # general reader (TableParser + StatedTotals: the Triangle Mastercard shape).
  module Layout
    LAYOUTS = [ Layouts::RbcChequing ].freeze

    def self.detect(text) = LAYOUTS.find { |layout| layout.matches?(text.to_s) }
  end
end
