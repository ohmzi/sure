# CSV mapping templates

Sure reuses your column mapping from a previous CSV import, so you do not have
to re-select the same columns every month for the same account. This is an
implicit template system: there is no saved "profile" you name, edit, or delete
— the most recent completed import *is* the template.

## What the template is

The template for a new import is the most recent `complete` import of the same
`type` (for example `TransactionImport`) on the same account. It is found by
`Import#suggested_template` (`app/models/import.rb`):

```ruby
family.imports
      .complete
      .where(account: account, type: type)
      .order(created_at: :desc)
      .first
```

Two consequences follow from that query:

- **Per account, not per family.** A different account has no template until its
  own first import completes.
- **Per import type.** A `TradeImport` template is never offered to a
  `TransactionImport`, even on the same account.
- Only `complete` imports qualify. Failed, reverted, or still-running imports
  never become templates.

## How the UI offers it

When you upload a CSV, the upload controller redirects to the configuration
screen with a hint parameter
(`app/controllers/import/uploads_controller.rb`):

```ruby
redirect_to import_configuration_path(@import, template_hint: true), notice: ...
```

On `GET /imports/:id/configuration?template_hint=true`, the view
(`app/views/import/configurations/show.html.erb`) checks for a
`suggested_template` and, when one exists, shows a "Template configuration
found" card with two choices:

- **Manually configure** — the normal column-mapping screen.
- **Apply template** — a button that sends `PUT /imports/:id/apply_template`
  (the member route in `config/routes.rb`). `ImportsController#apply_template`
  calls `@import.apply_template!(@import.suggested_template)` and redirects back
  to the configuration screen with a notice. If no template is found, it
  redirects with an alert instead.

Without the `template_hint=true` parameter (for example opening the
configuration screen directly from the import's steps), the card is not shown.
The manual configuration screen is always available.

## Which fields travel

`Import#apply_template!` copies the template's CSV parsing settings onto the new
import using an `attributes.slice`:

- Column labels: `date_col_label`, `amount_col_label`, `name_col_label`,
  `category_col_label`, `tags_col_label`, `account_col_label`,
  `qty_col_label`, `ticker_col_label`, `price_col_label`,
  `entity_type_col_label`, `notes_col_label`, `currency_col_label`,
  `exchange_operating_mic_col_label`
- Parsing settings: `date_format`, `signage_convention`, `number_format`,
  `rows_to_skip`

It does not copy the file contents (`raw_file_str`) or the column separator
(`col_sep`) — those are set by the new upload.

## Caveats

- **Implicit, not a named profile list.** There is no collection of saved
  profiles to choose from; only the single most recent completed import of that
  type and account is offered. Re-importing an older file with different columns
  will, once it completes, replace what the next import is offered.
- **Apply, then review.** `apply_template!` fills the configuration fields; the
  normal preview step still runs, so an incorrect mapping shows up as bad
  preview rows rather than silently importing.
- **The mapping is reused, not the mapping *rules*.** Signage and number/date
  formats travel as recorded values, so a bank that changes its CSV layout
  between exports needs those fields corrected on the new import before
  completing it.
