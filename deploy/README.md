# OhmzBudget deploy

Compose project `ohmzbudget`: the Rails app (`web`, `worker`, `worker-heavy`) and
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
attachments and the document store (`OHMZBUDGET_DOCUMENT_STORE_DIR` =
`/rails/storage/paperless-staged`). That path is FIXED: document rows store
absolute paths, so moving the root would strand every already-read document
(Ruling R25). The directory rename is deferred to Milestone B.

## Paperless removal (Ruling R23)

`paperless`, `paperless-db` and `paperless-valkey` were deleted from
`compose.yml` and their containers stopped. Their five named volumes are
intentionally LEFT ON DISK (`ohmzbudget_paperless-{data,media,consume,export,db}`).
Once the native read has been seen to work, remove them with:

```bash
docker volume rm ohmzbudget_paperless-data ohmzbudget_paperless-media \
  ohmzbudget_paperless-consume ohmzbudget_paperless-export ohmzbudget_paperless-db
```

## Files
- `compose.yml` — services, volumes, secrets, networks, hardening.
- `docker-compose.override.yml` — pins the two adopted bridge subnets.
- `.env.example` — template for the untracked `.env` (non-secret deploy vars).
- `dc` — required entry point: sources `.env`, exports the secret files, runs compose.
- `bootstrap-secrets.sh` — writes/re-homes secrets into `secrets/` (never prints a value).
- `backup.sh` / `restore-drill.sh` — nightly backup and the proven restore drill.
- `healthcheck-alert.sh` — host monitor (container health, disk headroom, backup
  freshness); cron-driven, see "Monitoring schedule" below.
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
   cd ~/StudioProjects/OhmzBudget
   set -a; . deploy/.env; set +a          # export ADMIN_EMAIL for the exec below
   deploy/dc exec -T -e ADMIN_EMAIL="$ADMIN_EMAIL" web ./bin/rails ohmzbudget:first_run < deploy/secrets/admin_password
   ```
   Both parts are required: `docker compose exec` does not forward the host
   environment (hence the export plus `-e ADMIN_EMAIL=…`), and the password is
   piped from the secret file, never argv.
4. `http://127.0.0.1:7300/up` answers 200; log in with the admin email — a fresh
   admin is redirected to `/onboarding` until the wizard is completed once, not
   to the dashboard.

## Everyday commands
- `./dc ps` / `./dc logs -f web` — status and logs.
- `./dc build web && ./dc up -d web worker worker-heavy` — rebuild after a code
  change (the three app services share the `ohmzbudget:local` image).
- Never run raw `./dc config` (or `docker compose … config`) against the live
  deployment — it renders the resolved secret values into its output. Validate
  with `./dc config --services` or `./dc config --quiet` instead.

## Upgrade the application image
The app image is built **locally from this checkout** (`image: ohmzbudget:local` +
`build: context: ..` in `compose.yml`); there is no registry tag to pull or bump.
An image upgrade is therefore a **rebuild**: it ships whatever source this checkout
holds right now. Record the current image before rebuilding, so you can get back
to it (`docker tag ohmzbudget:local ohmzbudget:rollback-<YYYYMMDDHHMM>`).

From the repo root:

```bash
git -C . rev-parse HEAD           # record the commit being deployed
deploy/dc images                  # record the current ohmzbudget:local image id
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
cd ~/StudioProjects/OhmzBudget
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
- `app-storage_<ts>.tgz` — the `ohmzbudget_app-storage` volume: the Active Storage
  attachments **and** the document store (`/rails/storage/paperless-staged`). With
  paperless gone this volume is the only copy of every uploaded original.

`<ts>` is `date +%Y-%m-%d_%H%M%S`; the run uses one timestamp for both files.
`BACKUP_DIR` must be set in the untracked `deploy/.env` — the script hard-requires
it and aborts with `set BACKUP_DIR in deploy/.env` when it is unset; this
deployment uses `/home/ohmz/ohmzbudget-backups/backups`. `BACKUP_KEEP_DAYS`
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
17 3 * * * /home/ohmz/StudioProjects/OhmzBudget-native-a/deploy/backup.sh >> /home/ohmz/ohmzbudget-backups/backup.log 2>&1
```

## Monitoring schedule
`deploy/healthcheck-alert.sh` (mode 0755, run from the host) checks that every
service in the current stack is running and none is unhealthy, that `DISK_MOUNT`
has headroom (`DISK_LIMIT_PCT`, default 90), and that the backup artifacts above
are fresh (`BACKUP_MAX_AGE_HOURS`, default 26). It matches on the compose **service
name**, so stopped orphan containers from the removed paperless service are
ignored. When healthy it prints one OK line and exits 0; on failure it posts one
JSON alert to `ALERT_WEBHOOK_URL` and exits 1. It sources `deploy/.env` itself,
because cron gives the job no environment. Until the owner sets `ALERT_WEBHOOK_URL`
in `deploy/.env`, a run aborts at the guard (message on stderr) — loud by design,
never silently healthy.

Host crontab entry (every 30 minutes; the log lives under the owner's backup
root, not `/var/log`):

```cron
*/30 * * * * /home/ohmz/StudioProjects/OhmzBudget-native-a/deploy/healthcheck-alert.sh >> "$HOME/ohmzbudget-backups/healthcheck.log" 2>&1
```

Confirm it is installed with `crontab -l | grep healthcheck`.

## Restore drill (proven)
`deploy/restore-drill.sh` (mode 0755) proves the newest dump is a real,
loadable backup — the M0 exit criterion. It **never touches the live database**:
it loads `sure_db_<ts>.sql.gz` into a scratch database
`ohmzbudget_restore_drill` on the same `db` container, compares it against live,
then drops the scratch database.

```bash
cd ~/StudioProjects/OhmzBudget
deploy/restore-drill.sh
```

What it does, in order, and what fails the run (any mismatch exits non-zero):

- Picks the newest `sure_db_*.sql.gz` and `app-storage_*.tgz` from `$BACKUP_DIR`
  (a missing app dump or storage archive aborts up front).
- `DROP DATABASE IF EXISTS` / `CREATE DATABASE ohmzbudget_restore_drill`, then
  loads the gzipped dump into it with `psql`.
- Compares `entries` **and** `users` row counts, live vs restored; they must be
  equal, and restored `users` must be `>= 1` (an empty dump cannot pass).
- Lists the first 5 entries of the storage archive (`|| true` guards the `head`
  SIGPIPE that would otherwise trip `set -euo pipefail` as archives grow).
- Asserts the document store (`/paperless-staged/`) is present inside the
  app-storage archive — with paperless gone that volume is the only copy of every
  uploaded original, so a set without it is not a backup of the documents.
- `DROP DATABASE ohmzbudget_restore_drill` — no scratch database is left behind.
- Prints `restore drill OK` and exits `0`.

Each run writes only to `ohmzbudget_restore_drill`; the live `sure_production`
database is read for the comparison counts and otherwise untouched. The drill is
the verification for the backup set, so run it after enabling cron and after any
schema or backup change.

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
cd ~/StudioProjects/OhmzBudget
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
docker run --rm -v ohmzbudget_app-storage:/data alpine:3.20 sh -c 'find /data -mindepth 1 -delete'
docker run --rm -v ohmzbudget_app-storage:/data -v "$BACKUP_DIR":/backup:ro alpine:3.20 \
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
`ohmzbudget` deploy project).

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
cd ~/StudioProjects/OhmzBudget
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
cd ~/StudioProjects/OhmzBudget
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
