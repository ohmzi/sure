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

---

# Milestone A — native document read: live acceptance run (2026-10-12)

Run on the deploy host against the running stack: compose project `ohmzbudget`,
`http://127.0.0.1:7300`, app commit `a2cbe001`. Every command below was run on
that stack; raw output is quoted verbatim. No secret value appears here.

## Step 0 — the live provider probe (the pre-condition)

```
$ cd deploy && docker compose exec -T web bash -lc 'bin/rails runner "
    p Provider::Registry.preferred_llm_provider&.provider_name
    p Provider::Openai.effective_model
    p ENV[\"OPENAI_URI_BASE\"].presence || Setting.openai_uri_base
  "'
nil
"gpt-4.1"
nil
```

**Result: no LLM provider is configured.** `preferred_llm_provider` is `nil` —
there is no `OPENAI_ACCESS_TOKEN` in the environment or in `Setting`, and no
Anthropic token either. `OPENAI_MODEL` and `Setting.openai_model` are blank, so
`effective_model` falls through to the OpenAI class constant `DEFAULT_MODEL`
(`"gpt-4.1"`); the URI base is blank too. Nothing points at DeepSeek, Ollama, or
OpenAI. (`Provider::Openai.configured?` is `false`; the only `Setting` rows are
`require_invite_for_signup` and `onboarding_state`.)

**Model configured: none.** `gpt-4.1` is the code's built-in fallback, not a
configured value. This is *not* the failure mode the brief anticipated (a legacy
`deepseek-chat` / `deepseek-reasoner` id) — it is the complete absence of a
provider, so the `image_url` question could not even be asked.

**Consequence (the headline).** The acceptance run's precondition — "with the
real configured provider (not a stub)" — is unmet. The milestone's central
unverified assumption (spec N4: one provider call carrying both the page images
and the OCR text, and that the provider accepts an `image_url` part) **could not
be exercised and remains unverified.** This is the same open item Task 5 flagged
and deferred to this run; it is still open. Steps 1–2 below are BLOCKED for that
reason.

Supporting evidence that the *pipeline* (not the provider) is wired: a real
upload through the app's own intake path (`DocumentLink::Intake.call` →
`DocumentUnderstandingJob`) ran the **real OCR sidecar** and produced text, then
held exactly at the provider step —

```
$ docker compose exec -T web bin/rails runner '<Intake.call(file: samples/receipt.png, enqueue: ->(l){ DocumentUnderstandingJob.perform_now(l.id) })>'
ACCEPT id=272f163e-489c-4954-acc8-2dc6da22e6ca status=queued
ACCEPT failure_message="no AI provider is configured"
ACCEPT stored_path_present=true
ACCEPT bytes_on_disk=52823
ACCEPT content_sha256_len=64
ACCEPT extracted_text_present=true
ACCEPT extracted_text="WHOLE FOODS MKT #12345\n123 Market Street\n2026-10-02\n14:32\nGroceries\n84.12\nTotal\n84.12\nVisa****1234\nThank you for shoppin"
ACCEPT extraction_nil=true
ACCEPT count_before=9 count_after=10
```

The OCR text is real (the sidecar read the image); the model's verdict is absent
because there is no model. `extraction` is nil, so nothing was invented.

## Step 1 — a real receipt photo

**BLOCKED — no provider configured (Step 0).** A receipt *can* be uploaded and
*is* read by the OCR sidecar (see Step 0's transcript: real text, bytes stored,
52823 B preserved), but the AI verdict cannot be produced, so "confirm it is
read" (a `DocumentExtraction` / a settled `unlinked` row) cannot be confirmed.
The document instead lands **held** with `failure_message = "no AI provider is
configured"` and `status = "queued"` — visible in the archive, bytes intact. The
`image_url` acceptance the milestone exists for was not run.

## Step 2 — a real multi-page statement

**SKIPPED / BLOCKED — no provider configured (Step 0).** No statement was
uploaded: with no provider the read cannot emit rows, so "confirm rows appear
and the count is sane" has no possible observation. The `statement.pdf` sample
exists in `deploy/samples/` for the run once a provider is configured.

## Step 3 — a document the system genuinely cannot read (a blank page)

**PASSED (the fail-closed path).** A generated blank page was uploaded; it lands
*needs your input* — held, not an error, not lost — and its bytes survive:

```
$ docker compose exec -T web bin/rails runner '<Intake.call(file: blank-page.png, enqueue: ->(l){ DocumentUnderstandingJob.perform_now(l.id) })>'
BLANK id=c4ad7c78-6bb3-414d-b52d-2336f88c72ea status=queued
BLANK failure_message="the OCR engine found no text in this document (unreadable)"
BLANK stored_path_present=true bytes=373
BLANK extraction_nil=true
```

`status = "queued"` with a reason, `extraction` nil (no invented verdict), and
the original bytes on disk. This is spec §10's "never a lost upload", observed
on the real stack.

## Step 4 — the OCR-down path

**PASSED (hold + automatic recovery); the final read is BLOCKED at the provider
— consistent with Step 0.**

```
# ocr stopped, a fresh document uploaded, then ocr started again:
$ docker compose stop ocr
 Container ocr Stopped
$ <Intake.call(file: recovery-receipt.png)>          # enqueued to the real Sidekiq `heavy` queue
RECOVERY id=834d1d00-590b-4578-8c9a-baf9970af5d3 status=processing msg=nil
# worker-heavy log, no operator action between these lines:
21:07:52 Performing DocumentUnderstandingJob ... heavy  → Retrying after 1 attempts in 3 seconds, due to Ocr::Error (Failed to open TCP connection to ocr:9000 ...)
21:07:59 Performing DocumentUnderstandingJob ... heavy  → Retrying after 2 attempts in 19 seconds, due to Ocr::Error (...)
21:08:20 Performing DocumentUnderstandingJob ... heavy  → Performed ... in 2571.28ms
$ (row read back)
NOW status=queued
NOW failure_message="no AI provider is configured"
NOW extracted_text_present=true
NOW extracted_text="RECOVERY TEST 203137061\nTotal 7.77"
NOW bytes=5517
```

While the sidecar was down the row was **held, not lost** (`status = "queued"`,
`failure_message = "retry scheduled: Failed to open TCP connection to ocr:9000
..."`, bytes preserved, and a retry landed on the real Sidekiq queue). After
`docker compose start ocr`, the **retry ladder re-read it with no operator
action** — backoffs 3 s then 19 s, and the third attempt read the document
through the real sidecar (the `extracted_text` above). The read then held at the
provider step, exactly as Step 0 predicts. `ocr`, `web`, `worker`,
`worker-heavy`, `db`, `redis` are all healthy after the run.

## Step 5 — the pre-existing archive is preserved

**PASSED.** Before the run: `DocumentLink.count` = **9**. After the run
(9 pre-existing + 4 acceptance uploads):

```
$ docker compose exec -T web bin/rails runner 'puts DocumentLink.count'   # intent: DocumentLink.not_deleted.count, which was 9
13
$ ... DocumentLink.order(:created_at) ...
DOC 2026-10-11T04:09:22 id=c85f6039-... status=linked   fname=receipt-wholefoods-2026-10-02.jpg
DOC 2026-10-11T04:09:34 id=4cdd3c50-... status=linked   fname=bill-acme-utilities-2026-10.pdf
DOC 2026-10-11T19:49:51 id=00599a57-... status=unlinked fname=Amazon Proof of Address.pdf
DOC 2026-10-12T03:42:09 id=c6d09add-... status=linked   fname=receipt.pdf
DOC 2026-10-12T03:43:27 id=5a588eb8-... status=dismissed fname=receipt2.pdf
... (all 9 pre-existing rows still present)
DOC 2026-10-12T21:06:50 id=272f163e-... status=queued   fname=acceptance-receipt.png
DOC 2026-10-12T21:07:41 id=c9b048b4-... status=queued   fname=ocrdown-receipt.png
DOC 2026-10-12T21:07:52 id=834d1d00-... status=queued   fname=recovery-receipt.png
DOC 2026-10-12T21:11:19 id=c4ad7c78-... status=queued   fname=blank-page.png
```

Note: the brief's `DocumentLink.not_deleted` is **not** a method in this
codebase (there is no soft-delete column); the equivalent is the plain count,
which was **9** before the run. All nine pre-existing rows are intact. The four
`queued` rows at the end are this acceptance run's uploads — they are held on the
missing provider and can be left as evidence or deleted.

## PAGE_BATCH observation

`DocumentUnderstandingJob::PAGE_BATCH` remains **4**, and it remains an
**acknowledged unmeasured placeholder**. Page batching happens only at the
*provider* call stage, so with no provider nothing in this run exercised a batch
and no throughput/latency figure can be derived for it. The only latency datum
observed is OCR-only (the real sidecar read a single page in ≈2.57 s), which does
not bear on `PAGE_BATCH` — that constant bounds the *provider* payload and token
budget, not the OCR. It cannot be raised on measurement until a provider is
configured and a real multi-page statement read with one.

## Not run / blocked summary

- Step 0 provider probe: **RAN** — the finding is that no provider is configured.
- Step 1 real receipt: **BLOCKED** on the provider (upload + OCR confirmed; verdict not).
- Step 2 multi-page statement: **SKIPPED** on the provider.
- Step 3 blank page: **PASSED** (fail-closed hold).
- Step 4 OCR-down path: **PASSED** for hold + auto-recovery; final read **BLOCKED** on the provider.
- Step 5 pre-existing archive: **PASSED**.

---

# Milestone B — the native documents surface: live acceptance run (2026-10-13)

Run on the deploy host against the running stack: compose project `ohmzbudget`,
`http://127.0.0.1:7300`, app commit `ebfbafb2` (image rebuilt from the worktree).
Every command below was run on that stack; raw output is quoted verbatim. No
secret value appears here.

## Step 0 — the live provider probe (the pre-condition)

```
$ ./dc exec -T web bin/rails runner '...'
preferred_llm_provider=nil
openai_configured=false
setting_llm_provider="openai"
openai_effective_model="gpt-4.1"
setting_rows=["require_invite_for_signup", "onboarding_state"]
```

**Result: no LLM provider is configured** — identical to Milestone A's finding.
`preferred_llm_provider` is `nil`; no `OPENAI_ACCESS_TOKEN` / `ANTHROPIC_*` token
is present in the environment or in `Setting`; the only `Setting` rows are
`require_invite_for_signup` and `onboarding_state`. `gpt-4.1` is the code's
built-in fallback, not a configured value. The probe was re-run against the NEW
Milestone B image after the deploy and returned the same result.

**Consequence (the headline).** Spec N4 — that the configured provider accepts an
`image_url` part — **could not be exercised and remains UNVERIFIED.** It is not a
`deepseek-chat`/`deepseek-reasoner` id problem (the brief's expected failure
mode); there is simply no provider at all, so the `image_url` question cannot
even be asked. Every acceptance step that needs a real read is therefore
**SKIPPED**, not passed.

## Step 0b — deploy pre-flight and the migrate

Backup first (the three new columns are additive, so a rollback is an image swap
plus a reversible `down`, but this is still the owner's real ledger):

```
$ ./backup.sh
backup complete: 2026-10-13_021708 -> /home/ohmz/ohmzbudget-backups/backups
$ ls -la .../sure_db_2026-10-13_021708.sql.gz .../app-storage_2026-10-13_021708.tgz
-rw-r--r-- 1 root root 854883  app-storage_2026-10-13_021708.tgz
-rw-rw-r-- 1 ohmz ohmz 106394  sure_db_2026-10-13_021708.sql.gz
$ gzip -t .../sure_db_2026-10-13_021708.sql.gz && echo "sql.gz OK"   # sql.gz OK
$ gzip -t .../app-storage_2026-10-13_021708.tgz && echo "tgz OK"     # app-storage.tgz OK
```

Both archives exist, are non-empty and pass `gzip -t`. The current image was
tagged for rollback (`ohmzbudget:rollback-202610130217` = `570ef399b413`, the
Milestone A image), and the compose project was confirmed to resolve to
`ohmzbudget` (six services) via `./dc config --services` before anything changed.

```
$ ./dc build web                 # Image ohmzbudget:local Built
$ ./dc up -d web worker worker-heavy
 Container ohmzbudget-web-1 Recreated ... Started
 Container ohmzbudget-worker-1 Recreated ... Started
 Container ohmzbudget-worker-heavy-1 Recreated ... Started
```

(The `paperless*` orphan-container warning is expected — those volumes stay on
disk per Ruling R23.) The `web` entrypoint runs `db:prepare`, applying the two
Milestone B migrations:

```
$ ./dc ps --format '{{.Name}} {{.State}} {{.Health}}'
ocr                    running  healthy
ohmzbudget-db-1        running  healthy
ohmzbudget-redis-1     running  healthy
ohmzbudget-web-1       running  healthy
ohmzbudget-worker-1    running  healthy
ohmzbudget-worker-heavy-1 running healthy

$ curl -s -o /dev/null -w 'local %{http_code}\n' http://127.0.0.1:7300/up
local 200

$ bin/rails runner '... column_exists? ...'
entries.ai_posted_at=true
document_links.deleted_at=true
document_links.auto_post_undone_at=true
schema_version=20261012200000
```

**Six services healthy, `/up` 200, three new columns present, schema at
`20261012200000`.**

## Step 1 — the dropzone takes a receipt and the grid shows it

Driven through the app's own intake (`DocumentIntake` → `DocumentLink::Intake` →
`DocumentUnderstandingJob.perform_now`), with the real OCR sidecar. No provider
is configured, so the read cannot settle a verdict — the document lands
**held** with its reason and its bytes, exactly as Milestone A observed:

```
$ bin/rails runner /tmp/accept.rb
DROP receipt id=0cebe959-... status="queued" source="receipt"
DROP failure_message="no AI provider is configured"
DROP bytes_preserved=true ocr_text_present=true extraction=nil
GRID count_before=10 count_after=11 in_page_relation=true
STRIP needs_attention_includes=true
```

The real OCR sidecar read the image (`ocr_text_present=true`), the original
bytes survive, `extraction` is nil (nothing invented), the row is in the
Documents page's own relation and in the "needs you" strip. **PASSED for the
surface; the AI read is BLOCKED on the provider.**

## Step 2 — content routing (CSV / OFX hand off to the import pipeline)

```
ROUTE csv  kind=csv record=TransactionImport
ROUTE ofx  kind=ofx record=OfxImport
```

A bank export dropped on the one dropzone is routed by CONTENT to the import
pipeline that knows how to read it. **PASSED.**

## Step 3 — the type facet narrows the one page

```
FILTER all=11 statements=4 receipts_bills=7
```

The `DocumentLink::Search` object the page uses narrows to statements (4) and to
receipts-and-bills (7) out of 11, and a cleared/`all` selection filters nothing.
The in-page chip click itself (radio → auto-submit → "All" clears) is exercised
in the system suite (`documents_surface_test`); it was not re-driven in a browser
here (no interactive browser is attached to the live stack). **PASSED (query
layer, live); the chip click-through is covered by the system suite.**

## Step 4 — the viewer panel

```
PANEL read   read?=true class="receipt" fields=["type","total","date","payee"] checks=4
PANEL unread read?=false reason="no AI provider is configured"
```

An unread document **explains itself** with its reason ("no AI provider is
configured") and the two ways forward. The panel's READED state (fields,
confidences, the checks) was shown against a succeeded extraction seeded for the
observation, **not a genuine live read** — because no provider exists to produce
one. **Unread panel PASSED; the read panel is BLOCKED on the provider** (the
render is covered by `document_viewer_test`).

## Step 5 — per-transaction provenance (document / manual / edited)

```
LINK attached=true entry_links=1
PROV document primary="document" label="from a document" edited=false
PROV manual   primary="manual"   label="entered by you"
PROV edited_after_amount_change=true
```

A document-backed entry reads "from a document"; a hand-entered row reads
"entered by you"; and a value changed after the read is marked as edited (and is
not before the change). **PASSED.**

## Step 6 — the auto-post

**SKIPPED — no provider configured (Step 0).** The gate needs a settled read
whose OCR and vision totals agree; with no provider there is no second read, so
no receipt can post itself and the undo / AI-posted-filter steps have no
subject. The full money path (post → the row's badge → the audit filter → undo
removes the entry while the document survives) is pinned by
`test/system/auto_post_test.rb` against a provider double. It remains **OWED on a
real provider.**

## Step 7 — delete-block-and-tombstone (N9)

```
DELETE unreconciled deletable=false blockers=["ACCEPTANCE DOC"]
DELETE reconciled  deletable=true
DELETE tombstoned  deleted_at_present=true in_not_deleted=false
PROV after_delete primary="document" source_deleted=true
```

A document whose derived entry is unreconciled **refuses** deletion and NAMES
what is in the way ("ACCEPTANCE DOC"); once the entry is reconciled the document
deletes, its bytes go, the row stays as a tombstone (out of `not_deleted`), and
the entry's provenance still reads "from a document" while naming the source as
deleted. **PASSED.**

## Step 8 — the run left nothing behind

The whole acceptance ran inside `ActiveRecord::Base.transaction { … raise
ActiveRecord::Rollback }`, and the job queue was the in-process test adapter, so
no incidental Sidekiq job was enqueued to the owner's real queues:

```
$ bin/rails runner /tmp/accept.rb
ROLLED_BACK document_links=10 entries=21
```

`DocumentLink.count` and `Entry.count` are unchanged from the pre-run baseline
(10 and 21). The pre-existing archive is intact (all 10 visible rows preserved).
**PASSED.**

## Not run / blocked summary (Milestone B)

- Step 0 provider probe: **RAN** — no provider configured; spec N4 (`image_url`)
  still **UNVERIFIED / OWED**.
- Step 0b deploy: **PASSED** — backup verified, image rebuilt, migrations
  applied, six services healthy, `/up` 200.
- Step 1 dropzone + grid: **PASSED** for the surface; the AI read is **BLOCKED**
  on the provider.
- Step 2 content routing (CSV/OFX): **PASSED**.
- Step 3 type facet: **PASSED** (query layer, live); chip click covered by the
  system suite.
- Step 4 viewer panel: unread **PASSED**; the read panel **BLOCKED** on the
  provider.
- Step 5 provenance: **PASSED**.
- Step 6 auto-post / undo / audit filter: **SKIPPED** — no provider.
- Step 7 delete-block-and-tombstone: **PASSED**.
- Step 8 non-mutation: **PASSED**.
- Browser-driven click-throughs (the dropzone gesture, the chip click, the
  viewer open): not re-driven against the live stack (no interactive browser);
  covered by `test/system/{documents_surface,auto_post,document_viewer,
  document_provenance,document_browser}_test.rb`.

## Final fix wave — redeploy (2026-10-13, controller)

After the acceptance run above, the whole-branch final review returned findings
that were closed in the final fix wave (`772439d2`..`8986e706`). Those changes
touch the viewer, the provenance resolver, the auto-post undo and the statement's
`PdfImport`, so the image was rebuilt and the stack recreated on the new build:

```
$ ./backup.sh
backup complete: 2026-10-13_033625 -> /home/ohmz/ohmzbudget-backups/backups
$ gzip -t .../sure_db_2026-10-13_033625.sql.gz && echo ok   # ok
$ tar -tzf .../app-storage_2026-10-13_033625.tgz >/dev/null # ok
$ ./dc up -d web worker worker-heavy
 Container ohmzbudget-web-1 Recreated ... Started
 Container ohmzbudget-worker-1 Recreated ... Started
 Container ohmzbudget-worker-heavy-1 Recreated ... Started
$ ./dc ps --format '{{.Name}} {{.State}} {{.Health}}'       # six services healthy
$ curl -s -o /dev/null -w 'up %{http_code}\n' http://127.0.0.1:7300/up   # up 200
```

- Pre-deploy image tagged for rollback: `ohmzbudget:rollback-202610130332`
  (= `f60857c7907d`). This wave adds **no migrations**, so a rollback is the image
  swap alone: `docker tag ohmzbudget:rollback-202610130332 ohmzbudget:local &&
  ./dc up -d web worker worker-heavy`.
- Post-deploy: six services healthy, `/up` 200, three columns present, **no pending
  migrations**, and the owner's archive unchanged (10 documents / 21 entries).
- **Spec N4 is still OWED — unchanged.** No provider credential exists in the
  container environment or in `Setting` (`openai_access_token` and
  `anthropic_access_token` both read empty; `preferred_llm_provider` is `nil`), so
  no real document could be read end to end. The read, the auto-post and the undo
  remain proven only against doubles. Wiring a credential is the owner's step.
- Note (pre-existing, not introduced here): Active Record Encryption is not
  configured on this stack, so the app logs a `[SECURITY]` warning that provider
  tokens and PII are stored **unencrypted at rest**. Worth setting the three
  `ACTIVE_RECORD_ENCRYPTION_*` keys before a provider token is added.
