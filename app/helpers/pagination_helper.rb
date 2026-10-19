module PaginationHelper
  WINDOW = 5

  # The pages the page changer shows (the owner, 2026-10-18): five from the
  # current page, then a gap and the last page — "1 2 3 4 5 … 311", or
  # "7 8 9 10 11 … 311" on page 7. The same at every width: five short numbers
  # and the last fit a phone's row, and the row scrolls rather than wraps if a
  # column is narrower still. Near the end the window shows the last five, and
  # a window that stops one short of the last page runs on into it rather
  # than putting a gap between neighbours.
  def pagination_window(page:, pages:)
    return (1..pages).to_a if pages <= WINDOW + 1

    first = [ page, pages - WINDOW + 1 ].min
    last_shown = first + WINDOW - 1
    return (first..pages).to_a if last_shown >= pages - 1

    (first..last_shown).to_a + [ :gap, pages ]
  end
end
