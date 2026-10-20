# Sure deploy

Compose project `sure`: the Rails app (`web`, `worker`, `worker-heavy`) and
the internal OCR sidecar (`ocr`). paperless-ngx was removed in Milestone A — the
app reads documents natively. Its named volumes are left on disk, undeclared by
compose, until the owner removes them (see "Paperless removal").

Acceptance test: see deploy/ACCEPTANCE.md

## Stack

- `web` — `./bin/rails server`, published on loopback `127.0.0.1:7300:3000`. Its
  entrypoint runs `db:prepare`, so it applies pending migrations on boot.
- `worker` — `bundle exec sidekiq` (the config/sidekiq.yml queue set).
- `worker-heavy` — `bundle exec sidekiq -q heavy`, the lane for
  `DocumentUnderstandingJob` (a 40-page statement runs for minutes), so a slow
  read does not occupy a slot the mailer and the syncs need.
- `db` — postgres:16.
- `redis` — redis:7-alpine (Sidekiq broker / cache).
- `ocr` — the PaddleOCR sidecar (Task 4). Internal-only (no published ports),
  GPU device reservation; `web`/`worker`/`worker-heavy` join the `internal`
  network to reach it at `OCR_SERVICE_URL`.

The `app-storage` volume (`/rails/storage`) holds both the Active Storage
attachments and the document store (`SURE_DOCUMENT_STORE_DIR` =
`/rails/storage/paperless-staged`). That path is FIXED: document rows store
absolute paths, so moving the root would strand every already-read document
(Ruling R25). The directory rename is deferred to Milestone B.

## Paperless removal (Ruling R23)

`paperless`, `paperless-db` and `paperless-valkey` were deleted from
`compose.yml` and their containers stopped. Their five named volumes are
intentionally LEFT ON DISK (`sure_paperless-{data,media,consume,export,db}`).
Once the native read has been seen to work, remove them with:

```bash
docker volume rm sure_paperless-data sure_paperless-media \
  sure_paperless-consume sure_paperless-export sure_paperless-db
```

## Files
- `compose.yml` — services, volumes, secrets, networks, hardening.
- `docker-compose.override.yml` — pins the two adopted bridge subnets.
- `.env.example` — template for the untracked `.env` (non-secret deploy vars).
- `dc` — required entry point: sources `.env`, exports the secret files, runs compose.
- `bootstrap-secrets.sh` — writes/re-homes secrets into `secrets/` (never prints a value).
- `backup.sh` / `restore-drill.sh` — nightly backup and the proven restore drill.
- `healthcheck-alert.sh` — host monitor (container health, disk headroom, backup
  freshness, document pipeline); cron-driven, see "Monitoring schedule" below.
- `.env` and `secrets/` — untracked live state (never committed).

## Hardening
Every service runs `restart: unless-stopped`, `security_opt: ["no-new-privileges:true"]`,
`cap_drop: ["ALL"]` and a `mem_limit`, with only the entrypoint caps each image needs
re-added: `CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID` for the postgres service, and
`SETGID, SETUID` for redis (it starts as root and `setpriv` into its user). `ocr` gets
the same app hardening — it is the one container parsing untrusted PDFs and images
through native code. `redis` is additionally `read_only` with a `/tmp` tmpfs. The app
root stays writable because the image writes several runtime paths; the isolation comes
from dropped caps and `no-new-privileges`. `deploy/dc exec -T web` is the service name
(`web`, never `app`).

## First-run order
1. `cp -n .env.example .env`; edit `ADMIN_EMAIL` to the real owner address (blocking).
2. `./bootstrap-secrets.sh` (Task 3) — writes/re-homes `secret_key_base`,
   `postgres_password` and `admin_password` into `secrets/` (never printed).
3. `./dc up -d --build`, then create the first admin from the repo root:
   ```bash
   cd ~/StudioProjects/sure
   set -a; . deploy/.env; set +a          # export ADMIN_EMAIL for the exec below
   deploy/dc exec -T -e ADMIN_EMAIL="$ADMIN_EMAIL" web ./bin/rails sure:first_run < deploy/secrets/admin_password
   ```
   Both parts are required: `docker compose exec` does not forward the host
   environment (hence the export plus `-e ADMIN_EMAIL=…`), and the password is
   piped from the secret file, never argv.
4. `http://127.0.0.1:7300/up` answers 200; log in with the admin email — a fresh
   admin is redirected to `/onboarding` until the wizard is completed once, not
   to the dashboard.
5. `./setup-local-ai.sh` — the local AI the stack is configured for (see
   [Local AI](#local-ai-default)). Re-run it any time; it changes nothing that is
   already in place.

## Local AI (default)
`compose.yml` defaults to `LLM_PROVIDER=local`: the assistant and the document
reader both use **qwen3.5:9b** served by Ollama on this host and reached at
`http://host.docker.internal:11434/v1`. `setup-local-ai.sh` installs the Ollama
service settings the app relies on (listen beyond loopback, a 32k context, a 60 s
keep-alive), pulls the model and checks it reports `vision` and `tools`.

The model was chosen on a bake-off through Sure's own code (2026-10-19):

| | qwen2.5vl:7b | qwen3.5:9b |
|---|---|---|
| Assistant tool calls (Sure's 43 real tools, 9 questions) | 0/9 — Ollama refuses tools | 9/9 |
| June card statement, 133 rows | 3/133 | 125–132/133, every amount exact |
| RBC chequing statement, 29 rows | 13/29 | 24/29 |

The app reads statements with the model's reasoning switched off
(`reasoning_effort: "none"`): with it on, a page took ~3 minutes and multi-page
reads came back empty. Statements Sure can read from their own text are read
deterministically regardless, and the model only fills in the bank and card
details. To use another model set `LOCAL_LLM_MODEL` in `deploy/.env` (or Settings ›
Self-Hosting); it needs both `vision` and `tools`. System health › AI status has
**Load local model** and **Run checks again** to warm it and confirm it.

## Everyday commands
- `./dc ps` / `./dc logs -f web` — status and logs.
- `./dc build web && ./dc up -d web worker worker-heavy` — rebuild after a code
  change (the three app services share the `sure:local` image).
- Never run raw `./dc config` (or `docker compose … config`) against the live
  deployment — it renders the resolved secret values into its output. Validate
  with `./dc config --services` or `./dc config --quiet` instead.

## Upgrade the application image
The app image is built **locally from this checkout** (`image: sure:local` +
`build: context: ..` in `compose.yml`); there is no registry tag to pull or bump.
An image upgrade is therefore a **rebuild**: it ships whatever source this checkout
holds right now. Record the current image before rebuilding, so you can get back
to it (`docker tag sure:local sure:rollback-<YYYYMMDDHHMM>`).

From the repo root:

```bash
git -C . rev-parse HEAD           # record the commit being deployed
deploy/dc images                  # record the current sure:local image id
# ... land the new source, then:
deploy/dc build web                       # one image, shared by web/worker/worker-heavy
deploy/dc up -d web worker worker-heavy   # the web entrypoint runs db:prepare (pending migrations)
deploy/dc ps                      # the app services move starting -> healthy (~60s)
```

A rebuild touches only the app containers; the data volumes (`postgres-data`,
`redis-data`, `app-storage`) are never recreated by it. Rolling back a
**destructive migration** still needs a restore, not just an image swap.

## Rotate the app secrets
`secret_key_base` and `postgres_password` live in untracked `deploy/secrets/`
(mode 400). Rotating `secret_key_base` invalidates existing sessions and any
Active Record encrypted columns, so treat it as a deliberate operation, not a
routine one. `postgres_password` must match the `POSTGRES_PASSWORD` the `db`
volume was initialised with — rotate it in the database (`ALTER USER … PASSWORD`)
and in the secret file together, then `deploy/dc up -d --force-recreate web
worker worker-heavy`. The paperless-era secrets (`paperless_*`) are dead — the
services that read them are gone — but the files are kept so the archived
volumes can still be opened by hand.

## Encryption keys (Active Record Encryption)
The app declares `encrypts` on MFA secrets, provider and bank tokens, and provider
payloads. Three keys protect those columns and are read from the environment:
`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `..._DETERMINISTIC_KEY` and
`..._KEY_DERIVATION_SALT`. On this stack they live in the untracked `deploy/.env`.

- **Back them up with `secret_key_base`.** The nightly database dump is not enough
  on its own: without the keys, the encrypted columns cannot be read. Losing them
  loses MFA secrets, provider tokens and the encrypted user email/name fields, and
  there is no in-app recovery path.
- **Generate a first set** with `deploy/dc exec -T web bin/rails db:encryption:init`.
  Write the values straight into `deploy/.env`; never commit them or leave them in
  shell history. `bin/rails db:encryption:init` prints secret values.
- **Enabling encryption on an existing database.** Rows written before the keys
  existed are unreadable until they are re-saved through `encrypts`. Run with
  `ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=true`, backfill and verify,
  then set it back to `false`. Leaving it true also widens queries and keeps
  accepting new plaintext writes.
- **Recovery.** If a key is lost or changed by accident, restore the previous
  values first; restarting with the old keys makes the columns readable again. Do
  not "fix" a failed decrypt by deleting rows.
- **Rotation.** Rails supports a list of primary keys (the last encrypts, all are
  tried), but this initializer wires one value per environment variable, so a
  rotating deployment needs a comma-separated parse before it can rely on that.
  More importantly, Rails does **not** rotate deterministic keys, and this app uses
  deterministic encryption for bank/provider tokens, user email and mobile device
  ids. Rotating those requires an offline decrypt-and-re-encrypt pass while the old
  key is still configured; a half-rotated table reads with neither key set. Treat
  key rotation as a maintenance-window operation with a tested restore point.
- After any key change, restart every app service (`deploy/dc up -d --force-recreate
  web worker worker-heavy`) and confirm the `[SECURITY] ActiveRecord Encryption is
  NOT configured` boot warning is gone.

## Tunnel (cloudflared)
The app is reached over a cloudflared tunnel; TLS terminates at the edge, so the
app runs with `RAILS_ASSUME_SSL=true` and `RAILS_FORCE_SSL=false` (see
`.env.example`) and generates `https://` URLs. The tunnel config/dashboard holds
the ingress rule — this tracked file shows only the placeholder hostname; a live
hostname lives solely in the tunnel config and in untracked `deploy/.env`:

```yaml
ingress:
  - hostname: budget.example.com      # live value lives only in the tunnel config, never in a tracked file
    service: http://127.0.0.1:7300
```

The app is the only published port, bound to loopback (`127.0.0.1:7300`); `ocr`,
`db` and `redis` publish nothing, so the cloudflared edge is the only way in. The
owner sets the live hostname in untracked `deploy/.env` as `TUNNEL_HOST` (never a
tracked file) for the probes:

```bash
cd ~/StudioProjects/sure
set -a; . deploy/.env; set +a          # TUNNEL_HOST is the untracked live value
curl -fsS -o /dev/null -w 'local   %{http_code}\n' http://127.0.0.1:7300/up   # 200
curl -fsS -o /dev/null -w 'tunnel  %{http_code}\n' "https://$TUNNEL_HOST/up"  # 200
ss -ltn | grep -E '(0\.0\.0\.0|\[::\]):7300\b' && echo "EXPOSED ON 0.0.0.0 — stop" || echo "loopback only"
```

A real credential login through the tunnel (cookie jar + CSRF from the sign-in
form; the password is read from the secret file by curl, never echoed):

```bash
set -a; . deploy/.env; set +a
token=$(curl -fsS -c /tmp/ohmz-tunnel-cookies.txt "https://$TUNNEL_HOST/sessions/new" \
  | grep -oP 'name="authenticity_token" value="\K[^"]+' | head -1)
curl -fsS -o /dev/null -w 'tunnel-login %{http_code}\n' -b /tmp/ohmz-tunnel-cookies.txt -c /tmp/ohmz-tunnel-cookies.txt \
  --data-urlencode "authenticity_token=$token" \
  --data-urlencode "email=$ADMIN_EMAIL" \
  --data-urlencode "password@deploy/secrets/admin_password" \
  "https://$TUNNEL_HOST/sessions"
curl -fsS -o /dev/null -w 'tunnel-home %{http_code}\n' -b /tmp/ohmz-tunnel-cookies.txt "https://$TUNNEL_HOST/"
```

Expected: `local 200` and `tunnel 200`; `loopback only`; `tunnel-login 302`,
then `tunnel-home 302` to `/onboarding` until the owner completes the wizard
once (or `200` once onboarding is complete); `/up` answers `200` with no
`http://` downgrade redirect.

## Backups
`deploy/backup.sh` (mode 0755, cron-driven) writes two timestamped artifacts into
`$BACKUP_DIR` and prunes the set:

- `sure_db_<ts>.sql.gz` — `pg_dump` of the app database (`db` container, local socket).
- `app-storage_<ts>.tgz` — the `sure_app-storage` volume: the Active Storage
  attachments **and** the document store (`/rails/storage/paperless-staged`). With
  paperless gone this volume is the only copy of every uploaded original.

`<ts>` is `date +%Y-%m-%d_%H%M%S`; the run uses one timestamp for both files.
`BACKUP_DIR` must be set in the untracked `deploy/.env` — the script hard-requires
it and aborts with `set BACKUP_DIR in deploy/.env` when it is unset; this
deployment uses `/home/ohmz/sure-backups/backups`. `BACKUP_KEEP_DAYS`
(default `14`) comes from the same file; artifacts older than `BACKUP_KEEP_DAYS`
are deleted (`find … -mtime +N -delete`, which also sweeps stray `*.part` files
and the dot-named `.*.sql` dump temps). Both names are fixed (consumed by the
restore drill and the healthcheck monitor, which asserts both are fresh).

Each database dump goes to a temp file, is verified (`pg_dump` exit status plus a
`PostgreSQL database dump` marker) and only then published to the fixed name via
a `.part` file and an atomic rename, so a failed `pg_dump` never leaves a
valid-looking `.sql.gz` for the restore drill or the healthcheck monitor to trust.
The volume archive gets the same verify-before-publish rule: it is written to a
`.part` name from a read-only mount, a non-zero `tar` exit or a failing `gzip -t`
removes the `.part` and aborts the run, and only a verified archive is renamed
into the fixed name — a `tar` that fails on an unreadable member still closes gzip
cleanly, so a direct `tar czf` at the fixed name would leave a gzip-valid but
incomplete `.tgz`. Run it
by hand with `./backup.sh`; if a dump fails the run aborts (non-zero exit) and is
logged (`backup FAILED: …`) on stderr, but it may leave no usable backup for that
run.

Host crontab entry (03:17 — off the top of the hour; the log lives under the
owner's backup root, not `/var/log`):

```cron
17 3 * * * /home/ohmz/StudioProjects/sure/deploy/backup.sh >> /home/ohmz/sure-backups/backup.log 2>&1
```

## Monitoring schedule
`deploy/healthcheck-alert.sh` (mode 0755, run from the host) checks that every
service in the current stack is running and none is unhealthy, that `DISK_MOUNT`
has headroom (`DISK_LIMIT_PCT`, default 90), and that the backup artifacts above
are fresh (`BACKUP_MAX_AGE_HOURS`, default 26). It also watches the document
pipeline: it fails when any `document_links` row is in `retry_exhausted`, when the
heavy lane holds more than `HEAVY_QUEUE_MAX` queued reads (default 15), or when
`DocumentReaperJob` has not recorded a heartbeat within `REAPER_MAX_AGE_MINUTES`
(default 20; the key is `sure:document_reaper:last_run` in Redis). Two age bounds
catch a wedge the liveness checks miss: a `queued`/`processing` read with no hold
reason that has not moved for `DOCUMENT_STALL_MAX_MINUTES` (default 60), and an
`imports` row still `importing`/`reverting` after `IMPORT_STUCK_MAX_MINUTES`
(default 90; `Import.clean` only reaps at 6 hours). It also watches the recorded
LLM provider failure share over `LLM_ERROR_WINDOW_MINUTES` (default 60): above
`LLM_ERROR_RATE_MAX` percent (default 50) once at least `LLM_ERROR_MIN_CALLS`
(default 5) calls were recorded. The Redis reads derive their
database index from `REDIS_URL` (falling back to the value in `compose.yml`, which
is `/1` for this stack) and pass it with `redis-cli -n`, because `redis-cli`
otherwise inspects db 0 while Sidekiq's keys are in db 1. It matches on
the compose **service name**, so stopped orphan containers from the removed
paperless service are ignored. When healthy it prints one OK line and exits 0; on
failure it posts one JSON alert to `ALERT_WEBHOOK_URL` and exits 1. It sources
`deploy/.env` itself, because cron gives the job no environment. Until the owner
sets `ALERT_WEBHOOK_URL` in `deploy/.env`, a run aborts at the guard (message on
stderr) — loud by design, never silently healthy.

Host crontab entry (every 30 minutes; the log lives under the owner's backup
root, not `/var/log`):

```cron
*/30 * * * * /home/ohmz/StudioProjects/sure/deploy/healthcheck-alert.sh >> "$HOME/sure-backups/healthcheck.log" 2>&1
```

Confirm it is installed with `crontab -l | grep healthcheck`.

## Restore drill (proven)
`deploy/restore-drill.sh` (mode 0755) proves the newest dump is a real,
loadable backup — the M0 exit criterion. It **never touches the live database**:
it loads `sure_db_<ts>.sql.gz` into a scratch database
`sure_restore_drill` on the same `db` container, compares it against live,
then drops the scratch database.

```bash
cd ~/StudioProjects/sure
deploy/restore-drill.sh
```

What it does, in order, and what fails the run (any mismatch exits non-zero):

- Picks the newest `sure_db_*.sql.gz` and `app-storage_*.tgz` from `$BACKUP_DIR`
  (a missing app dump or storage archive aborts up front).
- `DROP DATABASE IF EXISTS` / `CREATE DATABASE sure_restore_drill`, then
  loads the gzipped dump into it with `psql`.
- Compares `entries` **and** `users` row counts, live vs restored; they must be
  equal, and restored `users` must be `>= 1` (an empty dump cannot pass).
- Lists the first 5 entries of the storage archive (`|| true` guards the `head`
  SIGPIPE that would otherwise trip `set -euo pipefail` as archives grow).
- Asserts the document store (`/paperless-staged/`) is present inside the
  app-storage archive — with paperless gone that volume is the only copy of every
  uploaded original, so a set without it is not a backup of the documents.
- `DROP DATABASE sure_restore_drill` — no scratch database is left behind.
- Prints `restore drill OK` and exits `0`.

Each run writes only to `sure_restore_drill`; the live `sure_production`
database is read for the comparison counts and otherwise untouched. The drill is
the verification for the backup set, so run it after enabling cron and after any
schema or backup change.

Host crontab entry (monthly on the 1st at 04:17 — after the 03:17 nightly backup;
the log lives under the owner's backup root, not `/var/log`):

```cron
17 4 1 * * /home/ohmz/StudioProjects/sure/deploy/restore-drill.sh >> "$HOME/sure-backups/restore-drill.log" 2>&1
```

Confirm it is installed with `crontab -l | grep restore-drill`.

## Restore
This is the **standing restore procedure**; the drill above remains the routine
verification that a backup set is real, and never touches the live database. The
dumps are plain `pg_dump` output with **no `--clean`**: piping one into a
populated database fails on every `CREATE` while psql still exits 0 — a silent
no-op. Never pipe a dump into a populated database; restore into a scratch
database first, or DROP/CREATE the live one immediately before loading.

Work from the repo root. The shell has not sourced `deploy/.env`, so define the
backup dir first — without it `"$BACKUP_DIR"/sure_db_*.sql.gz` expands to
`/sure_db_*.sql.gz`, gunzip reads nothing, and the pipeline status would still
come from psql's 0:

```bash
cd ~/StudioProjects/sure
set -a; . deploy/.env; set +a
: "${BACKUP_DIR:?set BACKUP_DIR in deploy/.env}"
```

Stop the app writers, then load the newest Sure dump into a scratch database
(`-v ON_ERROR_STOP=1` turns a partial load into a failure instead of a zero
exit; the psql variables expand **inside** the container, where `deploy/.env`
put them):

```bash
deploy/dc stop web worker worker-heavy
deploy/dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS sure_restore;"'
deploy/dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE sure_restore;"'
gunzip -c "$(ls -t "$BACKUP_DIR"/sure_db_*.sql.gz | head -1)" | \
  deploy/dc exec -T db sh -c 'psql -q -U "$POSTGRES_USER" -d sure_restore -v ON_ERROR_STOP=1'
```

Sanity-check the scratch load (counts must be non-zero; with writers stopped they
should match live):

```bash
deploy/dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d sure_restore -tAc "select count(*) from entries;"'
```

Restore the app-storage volume with its writers stopped (`web`/`worker` own both
the Active Storage attachments and the document store). Restore onto a fresh
volume, or empty the target first so the extract is an exact copy rather than a
merge:

```bash
deploy/dc stop web worker worker-heavy
docker run --rm -v sure_app-storage:/data alpine:3.20 sh -c 'find /data -mindepth 1 -delete'
docker run --rm -v sure_app-storage:/data -v "$BACKUP_DIR":/backup:ro alpine:3.20 \
  tar xzf "/backup/$(basename "$(ls -t "$BACKUP_DIR"/app-storage_*.tgz | head -1)")" -C /data
```

Bring everything back and verify:

```bash
deploy/dc up -d
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7300/up   # 200
```

A stored document still streams (open one in Documents), and a balance
recomputes after a sync (trigger one from the account page). Drop the scratch
database once satisfied:

```bash
deploy/dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS sure_restore;"'
```

The paperless database and media volume are no longer part of the stack. The
`paperless-db` container is left stopped on disk with its volumes (Ruling R23);
if that data is ever restored by hand, use the archived `paperless_db_*.sql.gz` /
`paperless-media_*.tgz` against those volumes.

## Known retained data (§16.7)
The legacy `/var/backups/firefly` ledger dump is intentionally retained and is
**not** part of the backup set; do not delete it without the owner's say-so.

## Local development loop (test suite)
The host has no `ruby`/`bundle`, no `mise`/`asdf` and no `psql`/`redis-cli`, so
the recorded local-dev branch is **`containers`** — it is the executed,
evidenced loop below. The **host-Ruby** branch is the documented fidelity
upgrade and is *not* installed. Both use upstream's `.devcontainer/` stack (its
own `db`/`redis`/`selenium`; compose project `devcontainer`, separate from the
`sure` deploy project).

### Container branch (recorded default)
The dev stack's four published ports are loopback-bound — `127.0.0.1:5432`
(db), `127.0.0.1:4444` / `127.0.0.1:7900` (selenium), and
`127.0.0.1:${PORT:-3000}` (app) — a fork-only edit of upstream's
`.devcontainer/docker-compose.yml`, which published them on `0.0.0.0` (Docker
publishes bypass ufw, and a dev Postgres with dev credentials must not be
LAN-reachable). Host port 3000 is already held on this host (a host-network
container), so the `app` *service* cannot publish at all; that is fine, because
the test loop uses `compose run`, which publishes nothing. `PORT=3001 … up -d
app` is the escape hatch if the dev server itself is ever wanted.

One-time per dev data volume — start `db` first, then raise the limit (a
dev-volume-local setting persisted via `postgresql.auto.conf` — not a tracked
file, so a fresh dev data volume resets it). The dev Postgres defaults to
`max_locks_per_transaction = 64` (≈6.4k lock slots); `bin/rails test` forks one
worker per core, and each worker locks the whole 753-relation test schema during
its startup reconstruction — 24 workers × 753 relations ≈ 18k locks on a
24-core host, overrunning the table, so every run dies with `PG::OutOfMemory:
ERROR: out of shared memory` until it is raised:

```bash
docker compose -f .devcontainer/docker-compose.yml up -d db
docker compose -f .devcontainer/docker-compose.yml exec -T db psql -U postgres -c \
  "ALTER SYSTEM SET max_locks_per_transaction = '1024';"
docker compose -f .devcontainer/docker-compose.yml restart db
```

Build, prepare, smoke, full suite:

```bash
cd ~/StudioProjects/sure
docker compose -f .devcontainer/docker-compose.yml build app
docker compose -f .devcontainer/docker-compose.yml run --rm app bash -lc \
  'bundle install && bin/rails db:prepare'
docker compose -f .devcontainer/docker-compose.yml run --rm app bash -lc \
  'bin/rails test test/models/user_test.rb'   # smoke subset
docker compose -f .devcontainer/docker-compose.yml run --rm app bash -lc 'bin/rails test'
```

The repo is mounted at `/workspace` and gems cache in the `bundle_cache`
volume; the build context is the repo root and `.dockerignore` keeps `/deploy/`
(secrets) out of it. `docker compose run` publishes no app port (no
`--service-ports`), so the loop is unaffected by the host-3000 conflict.

### Host-Ruby branch (not installed; fidelity upgrade)
Needs a version manager (`mise`/`asdf` absent). A fresh `mise` install is
≥ 2025.10, where `.ruby-version` is not read until the ruby tool is enabled:

```bash
curl -fsSL https://mise.run | sh
export PATH="$HOME/.local/bin:$PATH"
cd ~/StudioProjects/sure
mise settings add idiomatic_version_file_enable_tools ruby
mise use ruby@3.4.9
mise install
mise exec -- ruby -v            # expect: ruby 3.4.9

# Postgres + Redis as containers (host has neither binary; 6379 is taken, so
# Redis is published on 6390)
docker run -d --rm --name ohmz-dev-pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:5432:5432 postgres:16
docker run -d --rm --name ohmz-dev-redis -p 127.0.0.1:6390:6379 redis:7-alpine
export DB_HOST=127.0.0.1 POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres \
       POSTGRES_DB=sure_test REDIS_URL=redis://127.0.0.1:6390/1 RAILS_ENV=test

mise exec -- gem install bundler
mise exec -- bundle install
mise exec -- npm install          # design tokens, per bin/setup
mise exec -- bin/rails db:prepare
mise exec -- bin/rails test test/models/user_test.rb
```

The same lock-table tuning applies to `ohmz-dev-pg` on this host before the
full suite (`ALTER SYSTEM SET max_locks_per_transaction`, then restart).
