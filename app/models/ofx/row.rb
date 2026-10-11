module Ofx
  # A single OFX transaction, normalized to Sure's shape. `amount` keeps the
  # statement's own sign (negative = debit); `Import::Row#signed_amount`
  # applies the import's signage convention afterwards, exactly as QIF and
  # the AI PDF path do.
  Row = Struct.new(:date, :amount, :payee, :memo, :fitid, keyword_init: true)
end
