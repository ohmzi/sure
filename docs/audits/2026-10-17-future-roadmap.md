# Sure — future roadmap

**Date:** 2026-10-17
**Purpose:** compare Sure with the products people actually choose for personal
finance, then propose the improvements and new features that would make Sure the
best self-hosted option — and competitive with the hosted leaders.

The immediate defects are in
[the current fix plan](2026-10-17-current-fix-plan.md). This document is about
what to build after those are stable.

---

## 1. Where Sure already wins

| Strength | Why it matters |
| --- | --- |
| **Self-hosted and open source** | No subscription, no data broker, full export. The strongest differentiator against Monarch/Copilot/YNAB. |
| **Native document pipeline** | PDFs, images and statements → OCR → deterministic text/geometry reader → local or cloud vision model → routed imports. Leaders either have no document upload (YNAB, Copilot) or only per-transaction attachments (Simplifi, Monarch). PocketSmith has a library but not the read-to-ledger pipeline. |
| **Local AI with cloud fallback** | Ollama for no-egress households, DeepSeek/Gemini when the local model cannot finish. Almost unique among consumer finance apps. |
| **Multiple bank providers** | Plaid, SimpleFIN, Lunchflow, Enable Banking, Akahu, Up, Monobank, Mercury, Redbark, FinanceKit and more — broader self-hosted coverage than most open-source alternatives. |
| **YNAB-shaped budgeting** | Envelopes, targets, rollover, credit-card payment envelopes. Actual Budget is the closest open-source peer; Sure adds documents and AI. |
| **Household sharing and permissions** | Account sharing, roles and guest restrictions. Copilot is single-user; YNAB and Monarch are household-capable. |
| **API, MCP and multiple clients** | Web, Tauri desktop, Flutter mobile, HTTP API and a Model Context Protocol endpoint for external agents. |
| **Operational maturity** | Docker stack, backups, restore drill, health checks, Pipelock/Brakeman. Many self-hosted apps stop at "docker compose up". |

## 2. Where leaders are ahead

Feature comparison (approximate; verify vendor pages before quoting publicly).
✅ = first-class, ◐ = partial/limited, — = not offered.

| Capability | Sure | YNAB | Monarch | Copilot | Simplifi | PocketSmith | Firefly III | Actual |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Bank sync breadth | ✅ many providers, self-hosted keys | ✅ | ✅ 13k+ institutions | ✅ Apple/US focus | ✅ | ✅ | ◐ GoCardless/Spectre + importers | ✅ GoCardless/SimpleFIN |
| Statement PDF → ledger | ✅ native read, reconciliation gate | — | ◐ | — | ◐ attachments | ◐ files, no read | ◐ import | — |
| Receipt/bill extraction | ✅ OCR + vision + review | — | ◐ attachments | — | ◐ Business & Personal receipt feature | ◐ documents, no extraction | — | — |
| Central document library | ✅ search, facets, viewer, duplicates | — | ◐ per transaction | — | — | ✅ Files library | — | — |
| Email-in documents | — | — | — | — | — | ✅ per account | — | — |
| Auto-categorization | ◐ rules + Bayes + LLM | ◐ payee learning, AI narratives | ✅ learns corrections | ✅ best-in-class, per-user ML | ◐ | ◐ | ◐ rules | ◐ basic rules |
| Rules engine | ✅ conditions/actions, order, compound | ◐ | ◐ | ◐ | ◐ | ◐ | ✅ regex/multi-condition, retroactive | ◐ basic |
| Rule review/dry-run | ◐ new review page, no dry-run | — | — | — | — | — | ◐ rule test | — |
| Statement reconciliation | ◐ printed-total checks, coverage | ◐ | ✅ | ✅ | ✅ | ✅ | ✅ audit trail | ✅ |
| Immutable financial audit trail | — | — | ◐ | — | — | — | ✅ | — |
| Budget targets/rollover | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ forecasting | ◐ | ✅ |
| Cash-flow forecasting | ◐ | ◐ | ✅ | ✅ | ✅ | ✅ best-in-class | ◐ | ◐ |
| Investment tracking | ✅ many providers | ◐ | ✅ | ✅ | ✅ | ✅ | ◐ | — |
| Multi-currency | ✅ | ◐ | ✅ | ◐ | ✅ | ✅ | ✅ | ◐ |
| Mobile app parity | ◐ login/balances only | ✅ | ✅ | ✅ Apple-first | ✅ | ✅ | ◐ browser | ✅ |
| AI assistant | ✅ built-in + MCP | ◐ 2026 AI features | ✅ | ✅ | ✅ | ◐ | — | — |
| Privacy / local AI | ✅ local Ollama, self-host | — | — | — | — | — | ✅ self-host | ✅ self-host |
| Compliance posture | ◐ self-hosted controls | SOC 2 | SOC 2 | SOC 2 | ✅ | ✅ | self-hosted | self-hosted |

## 3. Product principles for the next 12 months

1. **Documents first.** Sure's unique wedge is "drop the paper, get a reconciled
   ledger." Every document feature should shorten time-to-trust.
2. **Explain every automatic decision.** Category, transfer match, duplicate hold and
   reconciliation result must say who decided it and why.
3. **Local by default, cloud by consent.** Keep the no-egress path first-class; make
   the trade-off explicit per feature.
4. **One ledger, many clients.** The API/MCP is the contract; web and mobile are views.
5. **Boring reliability.** A finance app that loses a document or double-posts is
   worse than one with fewer features.

---

## 4. Roadmap

### Phase 1 — Trust and safety (0–30 days)

Objective: make the ledger trustworthy before adding breadth.

- Fix the P0 items in the current fix plan: encryption keys, red suite,
  pending imports, statement mismatches, categorization model/quality.
- Add the **reconciliation review** surface: per-check detail, expected vs actual,
  mark reviewed, and a clear "what is wrong" message.
- Add the **document-processing dashboard** and alerts (retries, exhausted holds,
  queue age, reaper health).
- Add the **financial audit trail** (actor, before/after, timestamp, request id) for
  category, merchant, amount, date, imports, document delete and export.
- Add a **data-quality panel**: statements with no account/period/identity, pending
  imports, uncategorized count, documents waiting, duplicate groups.
- Mobile: fix the remaining horizontal-scroll tables; verify the Statements month
  picker, viewer, duplicate review and categorize select-all on a phone.

**Exit criteria:** zero silent failures, every automatic write attributable, no
document lost across a worker kill/restart, suite green.

### Phase 2 — Categorization 2.0 and documents (30–90 days)

Objective: match or beat Copilot/Monarch on categorization, and PocketSmith on
documents.

**Categorization**
- Merchant normalization layer: canonical merchant, aliases, descriptor cleanup
  (`AMZN Mktp*` → Amazon), per-household overrides.
- Per-user learning loop: every human correction updates Bayes and a merchant→category
  memory; show the suggestion before applying when confidence is low.
- Confidence + explanation in the UI ("rule", "Bayes 0.91", "AI 0.72"); one-tap
  "clear AI category" and "this is wrong".
- Accuracy dashboard: first-pass accuracy, abstention, correction rate, per-category
  confusion; use the existing eval harness.
- Rule suggestions from repeated corrections ("You've corrected AMZN 6 times; create a
  rule?"), with a dry-run count and conflict preview.
- Optional regex/contains/starts-with operators, mirroring Firefly III.

**Documents**
- Email-in address per account (PocketSmith-style) that feeds the same intake.
- Document library upgrades: labels, saved searches, bulk actions, multi-file links to
  one transaction, version/merge.
- Field-level correction in the read panel (fix a payee/total/period and re-route
  without a full re-read).
- Statement split: one PDF containing multiple accounts/periods → multiple statements.
- Duplicate lifecycle: delete/merge statement rows with the document, and a
  "keep this one" action.
- Receipt line-item editing and split-to-budget from the receipt viewer.

**Trust**
- Auto-post gate transparency: show why a statement did or did not post (proven,
  identity, period, totals).
- "What changed" digest after an import: N rows, N matched, N new, N held.

### Phase 3 — Planning parity (90–180 days)

Objective: close the budgeting/forecasting gap with YNAB, Monarch, PocketSmith.

- **Forecasting**: projected balances and cash-flow for 1–12 months from recurring
  transactions, bills, goals and income; scenario toggles ("skip this bill").
- **Budgeting**: targets/scheduled targets, rollover visibility, age-of-money,
  underfunded envelope highlights, credit-card payment envelope explanation.
- **Goals**: multi-account goals, pledge automation, progress charts, what-if dates.
- **Reports**: custom report builder (dimensions: account/category/merchant/tag/
  period), saved reports, tax-year export, investment performance (TWR/IRR,
  benchmark), fee analysis.
- **Bills**: calendar view improvements, price-change detection, autopay status,
  "paid from which account" reconciliation.

### Phase 4 — AI-native assistant and automation (6–9 months)

Objective: make Sure's assistant the best way to operate a self-hosted ledger.

- Grounded assistant actions: "categorize everything from Amazon this year",
  "find receipts missing from my statement", "why is June over budget?" — with
  previews, confirmations and undo.
- Natural-language rule creation with a dry-run and explanation.
- Anomaly and subscription detection surfaced as insights (YNAB 2026 has an anomaly
  detector; Sure has an insight generator — connect them to documents and rules).
- MCP tools for documents, statements, reconciliation and rules (currently mostly
  read-oriented).
- Local-model evaluation: per-task model registry (categorization, document read,
  assistant) with quality/speed trade-offs and a benchmark page.

### Phase 5 — Ecosystem and assurance (9–12 months)

- Mobile parity: transactions, categorization, receipt capture, push notifications,
  offline queue, biometric unlock.
- Desktop: deep links, menu-bar quick add, secure local cache.
- Integrations: email-in, webhooks, Zapier/n8n, tax exports, payment-app imports.
- Provider health and fallback UX: one place to see which bank feeds are failing and
  why.
- Compliance-ready controls: encryption key rotation, immutable audit log export,
  retention policy, data-subject export/delete, least-privilege review, dependency and
  container scanning, a documented threat model and an external pen test.
- Community: contribution guide for new providers/document readers, a public eval
  leaderboard for categorization, feature flags for preview features.

---

## 5. Differentiated bets

These are the places where Sure can be meaningfully better, not just catch up:

1. **Documents → reconciled ledger with a local model.** No mainstream consumer app
   does this end-to-end with a no-cloud option.
2. **Explainable automation.** Every category, transfer match, duplicate hold and
   reconciliation result has provenance and an undo. Competitors mostly show a black
   box.
3. **Self-hosted AI.** A household can run categorization and document reading on its
   own hardware, with cloud as an explicit fallback.
4. **Open data and agents.** API + MCP + export make Sure a ledger other tools can use,
   rather than a silo.
5. **Statement truth.** A statement is evidence: Sure can reconcile it to the cent and
   keep the document as the audit trail, which spreadsheets and most apps cannot.

## 6. Metrics that matter

| Area | Metric | Target |
| --- | --- | --- |
| Documents | Read success without manual retry | > 98% |
| Documents | Median time from upload to review | < 5 min |
| Documents | Documents lost/silently held | 0 |
| Imports | Pending imports older than 24h | 0 |
| Categorization | First-pass accuracy on household history | > 90% |
| Categorization | Human correction rate | < 10% |
| Categorization | Abstention vs false-positive ratio | abstain when unsure |
| Reconciliation | Statements with an explained status | 100% |
| Security | Encrypted sensitive columns; audit-log coverage of financial writes | 100% |
| Reliability | Double-posted imports / duplicate entries | 0 |
| Performance | p95 transaction list / document viewer | < 500 ms server time |
| Mobile | Core flows available on phone | transactions, categorize, capture, view |

## 7. Risks and non-goals

- **Do not chase Copilot's per-user ML by copying a black box.** Prefer explainable
  Bayes + merchant memory + LLM, with confidence and undo.
- **Do not make cloud egress the default.** Local-first is the differentiator; cloud
  is a fallback the owner opts into.
- **Do not add a feature that cannot be audited.** Every automatic money/category
  change needs provenance.
- **Do not grow the provider list faster than the import/reconciliation quality.**
  A broken feed is worse than no feed.
- **Compliance claims.** Being self-hosted is not SOC 2. If Sure is ever hosted, the
  assurance work in Phase 5 is a prerequisite, not marketing copy.

## 8. Sources

- YNAB vs Monarch vs Copilot (2026) — categorization, rules, pricing:
  <https://walletgrower.com/compare/ynab-vs-monarch-vs-copilot>
- Best AI personal finance tools 2026:
  <https://dupple.com/learn/best-ai-personal-finance-tools>
- PocketSmith Files — central document library, email-in:
  <https://www.pocketsmith.com/blog/meet-files-a-proper-home-for-your-household-s-financial-documents/>
- Quicken Simplifi receipt/attachment feature threads:
  <https://community.simplifimoney.com/discussion/16915/new-feature-expense-receipts-for-quicken-business-personal>
  and <https://community.simplifimoney.com/discussion/comment/68394/>
- Actual Budget vs Firefly III — rules, imports, reconciliation, audit trail:
  <https://selfhosting.sh/compare/actual-budget-vs-firefly-iii/>
- Self-hosted personal finance overview:
  <https://selfhosting.sh/best/personal-finance/>
- Fintech security practices (encryption at rest, MFA, audit logs, retention):
  <https://moldstud.com/articles/p-building-secure-cross-platform-financial-apps-essential-finra-compliance-checklist>
