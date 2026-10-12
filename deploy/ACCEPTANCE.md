# Deploy acceptance checklist (owner)

Run against the live tunnel (`https://budget.example.com`). Record PASS/FAIL and
the observation per step in the milestone's acceptance run log. Sample files are
in `deploy/samples/`. Never paste a secret value into the run log.

**Milestone A (native document read) changed the stack:** paperless-ngx is gone;
documents are read natively by the app with the internal `ocr` sidecar. Step 0
below reflects the new service list; the document steps (5–7) are being restated
in Milestone A's own acceptance run.

0. Stack up. `deploy/dc ps --format '{{.Name}} {{.Health}}'` → `web`, `worker`,
   `worker-heavy`, `db`, `redis` healthy, and `ocr` healthy (it carries an
   image-level `/healthz` healthcheck). No `paperless*` services exist.
   `curl -sf http://127.0.0.1:7300/up` → HTTP 200.
1. Admin account. First login is the `super_admin`. Settings → Profile shows
   role `super_admin`; Settings → Hosting shows onboarding state `invite_only`
   (signup closed).
2. Invite a member. Settings → Profile → Invite member → add `member@example.com`
   as role Member. Observation: the pending invitation appears with a copyable
   accept link; sign out and open the link → the accept landing page names the
   inviter and the invited role ("… has invited you to join as Member."). Create
   the account, sign in → the member sees the household accounts they were
   auto-shared.
3. CSV import. Imports → upload `checking.csv` → map columns → Preview.
   Observation: 5 preview rows; nothing is written before Confirm. Confirm →
   5 entries appear on the account, balance moves by their sum, and a
   re-upload of the same file re-adds nothing — the rows are re-matched by
   date/amount/currency/name and re-linked (the sha256 "already archived"
   notice is the OFX/statement archive path, step 4 — Ruling M5-L2).
4. OFX import. Imports → upload `checking.ofx`. Observation: preview shows the
   OFX row (GROCERY STORE, -45.99, FITID 2024101500001); Confirm adds it once;
   re-upload creates no duplicate (external_id).
5. PDF statement. Imports → upload `statement.pdf`. Observation: with an LLM key
   configured the LLM path extracts rows and born-reconciles them; with no key
   the file is archived and paperless OCR → template path runs. The header
   `JPMorgan Chase Bank, N.A.` reaches the Chase template; a statement whose
   header matches no template lands in `needs_template` — never a silent guess.
6. Receipt. Documents → upload `receipt.pdf`. Observation: a document link row
   appears `processing`, then `unlinked` after OCR; open it → the preview
   streams through the app (browser never talks to paperless); `?kind=original`
   returns the original bytes, byte-identical to the sample (this paperless-ngx
   serves the whole body and ignores `Range`, so no live `Content-Range`
   appears — the 206 passthrough is pinned by M1's controller test against a
   stubbed upstream; Ruling M5-L2).
7. Reconciliation. On the entry matching the receipt, run the matcher (or wait
   for the ~10-min cron). Observation: a `suggested` / `pending_review` card
   appears in the reconciliations inbox; tapping Link sets `linked`; the entry's
   amount is unchanged (link-only, D8). Dismiss a candidate → it is never
   suggested again.
8. Envelope cycle (one full month). Envelopes page: RTA equals income minus
   assignments; assign the month to zero; overspend one envelope → it shows red;
   roll to the next month → the red carry follows the envelope while the
   `rollover_enabled` toggle governs only surplus; the credit-card payment
   envelope rises with categorised card spending and falls with a `cc_payment`
   transfer.
9. SimpleFIN. Settings → Providers → SimpleFIN → paste a fresh setup token.
   Observation: accounts are discovered, you link them, the first sync imports
   transactions and balances, and a second sync creates no duplicates. Confirm
   the access URL is stored (Settings → Providers) and never appears in a log.
10. Round-trip. Export the family (Exports) and import `all.ndjson` into a
    scratch family. Observation: `rollover_enabled`, `rolled_over_amount`,
    `target_*` and household `user_id` survive (cross-check Task 6's test).
11. Restore. Take a backup; restore into a scratch DB per the deploy README.
    Observation: `/up` 200, a stored document still streams, a sync recomputes a
    balance. Run `BACKUP_DIR=/tmp/ohmzbudget-empty-backups ALERT_WEBHOOK_URL=<hook> deploy/healthcheck-alert.sh`
    → exit 1 and one alert delivered.
