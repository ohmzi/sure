class StatementTemplate
  # One parsed statement line. `amount` keeps the statement's sign
  # (negative = debit); the PdfImport row pipeline flips it the same way the
  # AI path does.
  Row = Struct.new(:date, :amount, :payee, :memo, keyword_init: true)
end
