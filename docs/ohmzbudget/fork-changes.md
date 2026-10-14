# OhmzBudget — what this fork changes

This repository is `OhmzBudget`, a working fork of [`we-promise/sure`](https://github.com/we-promise/sure)
that runs as a self-hosted household finance app. This file records what the fork adds and what it
changes about upstream, so a reader can tell the two apart.

It is the **additive** half of the pair: [`upstream-rebase.md`](upstream-rebase.md), beside it, holds
the per-file contact surface — every upstream file the fork modifies, with what to re-check on a
rebase. That file is the authority when the two overlap.

## What the fork is for

Three things, in the order they were built: a **document pipeline** (a receipt, bill or statement
arrives; it is read — OCR plus a vision read, or for a statement the document's own text layer; and
it becomes reviewed transactions, each traceable to the document it came from); **envelope
budgeting** in the shape YNAB users expect, on top of Sure's budget tables; and a **deployable,
observable self-hosted stack** with backups that have been restore-drilled.

## The milestones it was built in

| | | |
| --- | --- | --- |
| M0 | Foundation | the fork at its upstream pin, in its own compose project, with its own secrets, hardened containers and nightly backups |
| M1 | Document bridge | paperless-ngx as the headless OCR/archive engine: an uploaded receipt, bill or statement is posted, polled to completion, shown, and linked to an entry |
| M2 | Statement import | OFX/QFX files and scanned-PDF statements become reviewed entries through the preview→confirm flow, with unknown banks landing in an explicit `needs_template` state rather than an invented parse |
| M3 | Reconciliation | an archived receipt is matched to its transaction and confirmed or dismissed in a review inbox — link-only, never writing money |
| M4a | Zero-based budgeting core | Sure's envelope machinery as a ZBB surface: a Ready-to-Assign pool, signed red carry, one-gesture cover-overspend, per-envelope targets and a writable API |
| M4b | Credit envelopes | a YNAB-style payment envelope per credit card, materialized per budget month and card, so funded card spending moves money onto the payment envelope |
| M5 | Household ops | a real bank feed through SimpleFIN, invitation-flow gaps closed, deployment observable and recoverable, and the envelope export/import round-trip |
| M6 | Rebrand — **deferred** | scoping note only: the owner decided on 2026-10-10 that there is no rebranding, so the app continues to run as Sure and this stays an open question rather than work in flight |
| M7 | Intake wizard | the home screen's New popup gains Receipt-or-Bill and Statement rows, each opening a wizard: camera or upload, then confirm the account |
| M8 | Document browser | Receipts & Bills and Statements become first-class sidebar pages with the normal app chrome, not settings sub-pages |
| Native A | Reading core | paperless is replaced by a native read: a PaddleOCR sidecar, one vision call that reconciles the OCR text against the page images, and a provenance record for every document |
| Native B | Documents surface and auto-post | one upload place, one Documents page, every transaction traceable to its source, receipts that post themselves under an auditable gate — and a **deterministic statement reader** that parses a statement's rows from its own text layer and proves them against the statement's own printed totals before anything is written |

## What it adds

As of the 2026-10-14 rebase onto upstream: **324 new files**, including **16 migrations**, alongside
changes to 286 upstream files (the contact surface the runbook tracks).

- **The native document pipeline** — `app/models/document_*`, `app/models/statement_read*`, the
  intake/dropzone surfaces, the Documents browser and its viewer, the provenance resolver that says
  where a transaction came from, and `ocr/` — a PaddleOCR sidecar service with per-line bounding
  boxes, which is also what lets a scanned statement be read from its layout rather than guessed at.
- **Envelope budgeting** — the budgets/envelopes surfaces, per-envelope targets, the credit-envelope
  calculator, and `/api/v1/envelopes`.
- **Statement and file import** — OFX/QFX parsing, statement profiles, needs-template handling, and
  the reconciliation inbox.
- **The deploy stack** — `deploy/`: a compose project, the `dc` control script, backups, a proven
  restore drill, container healthchecks and an alert path, all described in `deploy/README.md`.
- **Docs** — `docs/llm-guides/` (architecture, design system, testing, provider work, feature
  gating), `docs/hosting/` per-integration notes, and `docs/ohmzbudget/`.
- **Tests** — fixtures, system tests and VCR cassettes for the provider paths, throughout.

## The migrations it adds

The schema additions are all additive: `document_links` and `document_extractions` (the pipeline's
spine and its provenance record), `account_statements` extraction state, `document_links.extracted_text`,
the import link and understanding state, budget-category targets, `credit_envelopes`, `ai_posted_at`
on entries, `document_links.deleted_at` (tombstones), plus a drop of the paperless-era columns with a
backfill for rows that were mid-flight when they went away.

## How it runs

Self-hosted, from this checkout: `deploy/dc` drives a compose project (`deploy/README.md` is the
runbook — an upgrade is a rebuild plus `up -d` for all three app services, `worker-heavy` included,
since that is the container the document job runs in).

## Staying in sync with upstream

Upstream is very active, so the fork is rebased on a schedule rather than ad hoc. The procedure, the
contact surface and the per-file re-checks are in [`upstream-rebase.md`](upstream-rebase.md).
