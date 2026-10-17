# Sure — current fix plan

**Date:** 2026-10-17
**Scope:** the self-hosted Household instance, the document pipeline, categorization,
rules, statements, and the UI work shipped in this session.
**Method:** production data snapshot, code review of the changed areas, the full Rails
suite, and the operational logs from the running Docker stack.

This is the short-horizon companion to
[the future roadmap](2026-10-17-future-roadmap.md). It lists what is wrong or
incomplete today, in the order it should be fixed.

## Snapshot (production, at time of audit)

| Metric | Value |
| --- | --- |
| Accounts | 3 (RBC Chequing, RBC Savings, Canadian Tire Mastercard) |
| Transactions | 2,396 |
| Categorized | 2,200 (91.8%) |
| Uncategorized | 196 |
| Categories | 23 |
| Rules (user-created) | 42 |
| Pending imports | 10 (136 rows, all RBC Savings) |
| Documents | 40 (2 linked, 38 unlinked) |
| Duplicate groups | 0 (the 5 old chequing copies were deleted) |
| Test suite | 12,956 runs, 5 failures, 0 errors, 34 skips |
| Document in flight | 0 |

Statement coverage for RBC Chequing 2026: **Jan–Apr covered, May–Sep mismatched,
Oct–Dec not expected**. The card's **May 2026 statement is missing**.

---

## P0 — fix first

### 1. ActiveRecord Encryption is not configured (security)

**Evidence.** Every production boot logs:

> `[SECURITY] ActiveRecord Encryption is NOT configured. Sensitive data (API keys,
> provider/bank tokens, MFA secrets, and PII) are being stored UNENCRYPTED at rest.`

The code already calls `encrypts` on MFA secrets, provider payloads and several
provider credentials (e.g. `app/models/user.rb:13`, `app/models/plaid_account.rb:6-12`,
`app/models/enable_banking_item.rb:8-11`). Without the three
`ACTIVE_RECORD_ENCRYPTION_*` keys those attributes are not protected by the app's
key management.

**Why it matters.** A database backup, a volume snapshot, or a stolen `pg_dump` exposes
bank tokens, provider payloads, MFA secrets and encrypted-column data. This is the
highest-risk finding in the audit.

**Fix.**
1. Generate the three keys (`bin/rails db:encryption:init`) and store them outside the
   database — in the deploy environment or Rails credentials. Back them up with the same
   care as `secret_key_base`.
2. Restart web and workers; confirm the boot warning is gone.
3. Audit every `encrypts` column. Attributes written **before** keys existed need a
   rotation/migration pass: read the value with the old path, rewrite it through
   `encrypts`, or force a provider token refresh. Do not assume enabling the keys makes
   existing rows decryptable.
4. Rotate provider tokens and MFA secrets that were stored while unencrypted.
5. Document key rotation and recovery in `deploy/README.md`.

**Acceptance.** No boot warning; a spec that writes and re-reads an `encrypts`
attribute passes with the keys injected; the deploy README documents rotation.

### 2. Statement reconciliation backlog and mismatches

**Evidence.**
- 10 RBC Savings imports are pending, with 136 rows total, waiting for review/publish.
- RBC Chequing's coverage reports **May–Sep 2026 as mismatched** (the rows do not add up
  to the closing balance). Five months of checks fail.
- 196 transactions remain uncategorized (mostly transfers, ATM withdrawals, one-sided
  e-transfers).
- The credit-card **May 2026 statement** was never uploaded.

**Why it matters.** A statement that is read but not published leaves money out of the
ledger. A reconciliation mismatch means either the parser/routing is wrong or the
statement is incomplete; either way the coverage badge is telling the owner not to trust
that month.

**Fix.**
1. Investigate one mismatched month end-to-end: compare the parsed opening/closing
   balance, the row sum, and the printed statement. Decide whether the cause is the read,
   the import row (sign, missing row), or the check itself.
2. Add a reconciliation-detail surface on the account statement page: per-check values,
   the expected vs actual totals, and a "mark reviewed" action when the owner has checked
   it by hand.
3. Publish the 10 pending savings imports (review each; their periods are now correct).
4. Run the same "pending import" sweep for every account and surface a global count on
   the Documents attention strip.
5. Upload the missing May 2026 credit-card statement.
6. For the 196 uncategorized rows, run the Quick Categorize wizard group by group and
   let Bayes/LLM learn; the long tail is intentional (it is mostly transfers and
   person-to-person moves, not spending).

**Acceptance.** Zero pending imports after review; every expected statement has a
coverage status the owner can explain; the uncategorized count reflects only rows that
genuinely have no category.

### 3. The five failing tests

The full suite is red on the branch for reasons unrelated to this session's work:

- `Documents::ProvenanceViewTest#test_a_receipt-born_entry_renders_its_producing_document_exactly_once`
- `Entries::AutoPostsControllerTest#test_the_row_and_the_drawer_name_the_app_as_the_author_and_link_its_document`
- `ProviderMerchant::EnhancerTest#test_returns_zero_counts_when_no_LLM_provider`
- `Transactions::ProvenanceAmountViewTest#test_a_receipt-born_row_links_its_amount_to_its_receipt`
- `Transactions::ProvenanceAmountViewTest#test_a_statement-born_row_links_its_amount_to_the_producing_document`

The provenance tests expect the old viewer URL without `?entry_id=`; the provider-merchant
test has a DeepSeek mock expectation that no longer matches the provider order. Fix these
before the next PR. A red suite hides new regressions.

**Acceptance.** `bin/rails test` is green; CI enforces it.

### 4. Categorization quality and the feedback loop

**Evidence.**
- The default local model is `qwen2.5vl:3b`. On the live data it mislabeled Esso as
  Shopping; the 7B model got the same row right. The one-time backfill used the 27B model.
- The LLM path locks the category it writes, so a later, better run cannot correct an AI
  mistake without an explicit unlock/reset.
- Confidence is only gated for the Jev classification provider. LLM answers carry no
  confidence.
- 42 rules now exist. The new rule review page can recategorize matched rows, but there is
  no accuracy dashboard, no rule-conflict warning and no dry-run count before applying.
- `Credit Card Payment` (a transfer category) appears in the budget category list with
  $0 assigned/spent.

**Fix.**
1. Add a **categorization model setting** (or use the current local model setting
   explicitly for categorization) and recommend `qwen2.5vl:7b`+ for categorization; the
   3B model is a document reader, not a reliable classifier.
2. Surface AI provenance and confidence on the transaction row/drawer ("AI · 0.82",
   "Bayes", "rule"). Make "clear AI category" one tap.
3. Use the existing eval runner (`app/models/eval/runners/categorization_runner.rb`) to
   measure first-pass accuracy on the household's own history; add a small dashboard of
   accuracy, abstention rate and correction rate.
4. Exclude system/transfer categories (`Credit Card Payment`, investment contributions)
   from budget category lists, or mark them non-budgetable.
5. Add rule dry-run counts and a conflict warning to the rule review page; show which
   higher rule claims a transaction.

**Acceptance.** A sample of 100 categorized rows reviewed by the owner shows fewer than
~10% corrections; every AI/rule-assigned row says where its category came from; budget
categories contain only spendable categories.

### 5. Document pipeline durability (implemented; finish the operational side)

This session added the durable retry state, processor lease/heartbeat, orphaned-owner
recovery, the five-minute reaper and the Sidekiq boot sweep, plus the transient/terminal
hold split and the cloud fallback. Remaining work:

- Add a **document-processing dashboard**: in-flight, waiting, retrying, exhausted, and
  per-lane queue depth. `DocumentLink` now has `attempts_count`, `failure_code`,
  `next_attempt_at` and `processing_owner` to drive it.
- Alert when a document exhausts retries, when the heavy queue is backed up, or when the
  reaper itself has not run.
- Add a failure-injection test: kill the worker mid-read, restart, and assert the read
  resumes without duplicate extractions.
- Tune `PROCESSING_LEASE` against the real worst-case provider call (currently 30
  minutes).
- Keep the cloud fallback on and document the local-vs-cloud privacy trade-off in the
  settings UI.

**Acceptance.** A worker killed mid-read is resumed within one lease + one reaper tick;
no document reaches `retry_exhausted` without an alert; the dashboard shows every
unfinished document.

---

## P1 — important, next

### 6. Rules engine and rule review

- The new `/rules/:id` page lists matched transactions and can update the rule or selected
  rows. Next: a preview count before applying, a diff of what will change, "apply to all
  matched" with a confirmation, and an undo path.
- Rules support name/amount/type/merchant/category/tag/details/notes/account and compound
  AND/OR, but **no regex**. Firefly III's regex rules are a genuine differentiator in the
  self-hosted market; add an opt-in regex operator with a safety note.
- Show rule order and "top rule wins" conflicts on the review page.

### 7. Duplicate and statement-row lifecycle

- Deleting a duplicate document now hides its statement from coverage and the vault
  (`AccountStatement.excluding_tombstones`), but the statement row and any import remain.
  Decide whether "Delete document" should also delete an unimported statement, or offer
  "Delete statement" as a separate action.
- Duplicate detection is by account + printed period. Strict overlap fixed the
  false-positive months. Add a review hint when two statements overlap by more than a
  boundary but have different printed balances.

### 8. Mobile and client parity

`docs/clients.md` is explicit: the Flutter mobile app is a login/balances companion; the
macOS app is a Tauri shell around the web app. Industry leaders are mobile-first
(Copilot is Apple-first; Monarch/YNAB have full mobile apps). Priorities:

- Mobile: transactions list + categorization + document capture/receipt upload + push
  notifications.
- Web: the imports archive table still scrolls horizontally on a phone; convert it to
  cards like the categorize rows.
- Desktop: deep links for documents/transactions and offline-safe error states.

### 9. Security and audit trail

- MFA (TOTP + WebAuthn) and passkeys exist; Rack::Attack, Brakeman and Pipelock are in
  place. See P0.1 for the encryption gap.
- `SSOAuditLog` covers SSO only. Financial edits (category/merchant/amount/date changes,
  imports, document deletes, exports) have no immutable user-facing trail. Firefly III
  records who changed what and when. Add an append-only audit log with actor, before/after
  and request id, and show it on the transaction/statement detail page.
- Document retention/export/delete: `FamilyExport` exists; make sure document bytes and
  derived records are included in the export and deletion story.

### 10. Observability and SLOs

- Add counters/timers for: document reads by outcome (proven, unverified, held, retried,
  exhausted), provider latency/error rate, categorization accuracy/correction rate,
  import publish latency, and queue age.
- Turn the existing `DebugLogEntry`, `AiHealth` and `healthcheck-alert.sh` into an
  operator dashboard; alert on thresholds, not just liveness.
- Track backup freshness and prove a restore monthly (the drill exists — schedule it).

### 11. Data-quality guardrails

- Validate statement `period_end_on` against the filename/printed period and surface a
  "period looks wrong" warning.
- Reject/normalize amounts with a sign convention mismatch (the import already tries).
- Surface statements with no account, no period, or no printed identity in the Documents
  attention strip.
- Make the account statements page's "mismatched" checks explain themselves (see P0.2).

### 12. Performance

- Use the public Skylight dashboard and the app's own DebugLog to find the slowest
  endpoints; the transactions list and reports are the usual suspects.
- Audit N+1s on the document/provenance pages (the transaction index preloads heavily;
  verify new surfaces do too).
- Keep the LLM usage/cost log (`LlmUsage`) visible in system health.

---

## P2 — polish

- Localization: new strings shipped only in `en`; the fallback covers other locales, but
  the vault/form/duplicate/rules strings should be translated.
- Copy: replace remaining "inbox" language in the statement vault (the shortcut is now
  "Statement vault").
- Empty states: documents with no read, statements with no account, duplicate groups
  reduced to one.
- Accessibility: verify the new month grid, duplicate rows, and rule review forms with
  keyboard and screen readers; the pills/checkboxes use `pointer-coarse` targets.
- Remove or use the now-unused statement strip partial/method (`UI::AccountPage#recent_statement_checks`)
  if the strip is not coming back.

---

## Verification plan

1. `bin/rails test` green (fix the five listed failures).
2. Run the affected system tests: documents, statements/vault, rules, categorization,
   auto-post.
3. Restore drill and backup freshness check after the encryption-key change.
4. Document failure-injection test (kill worker mid-read).
5. Manual acceptance on a phone: Statements tab (month tap, chart update, clear), document
   viewer, duplicate group, categorize group select-all, rule review.
6. Data checks after fixes:
   - `imports where status != complete` = 0 after review.
   - Uncategorized count is only genuinely ambiguous rows.
   - No `DocumentLink` in `retry_exhausted` without a user-visible reason.
   - Coverage months are covered/mismatched/not_expected with a known cause.

## Sources for the industry comparison

- YNAB vs Monarch vs Copilot (2026) — auto-categorization, rules, pricing:
  <https://walletgrower.com/compare/ynab-vs-monarch-vs-copilot>
- PocketSmith Files — central document library and email-in:
  <https://www.pocketsmith.com/blog/meet-files-a-proper-home-for-your-household-s-financial-documents/>
- Quicken Simplifi receipt/attachment threads:
  <https://community.simplifimoney.com/discussion/16915/new-feature-expense-receipts-for-quicken-business-personal>
- Actual Budget vs Firefly III — rules, imports, reconciliation, audit trail:
  <https://selfhosting.sh/compare/actual-budget-vs-firefly-iii/>
- Fintech security practice review (encryption at rest, MFA, audit logs, retention):
  <https://moldstud.com/articles/p-building-secure-cross-platform-financial-apps-essential-finra-compliance-checklist>
