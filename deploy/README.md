# OhmzBudget deploy

Compose project `ohmzbudget`: the Rails app (`web`, `worker`) and the re-adopted
paperless-ngx sidecar (`paperless`, `paperless-db`, `paperless-valkey`).

## Status (2026-10-10)

**Done** — deployed and verified end to end. The seven services are up (`web`
on `127.0.0.1:7300` answering `/up` 200, paperless on `127.0.0.1:7301`; nothing
binds `0.0.0.0`). Secrets are bootstrapped (untracked, mode 400) and the
paperless API token rotated; migrations have run, the first `super_admin`
exists, and a real credential login works (a fresh admin is redirected to
`/onboarding` until the wizard is completed once). Signup policy, the stable
`SECRET_KEY_BASE` across `--force-recreate`, and the re-attached paperless
volumes (baselines unchanged) were all verified. Nightly backups run from cron
(03:17, verify-before-publish) and the restore drill has been proven against
the newest dumps. The container local-dev loop is green (full suite
`11046 runs, 0 failures`; smoke `92 runs, 0 failures`).

**Left** — owner-gated only:

1. Set the cloudflared ingress for the live host and `TUNNEL_HOST` in untracked
   `deploy/.env` (currently unset), then run the tunnel probes and the
   credential login in "Tunnel (cloudflared)" below — expected `local 200`,
   `tunnel 200`, `tunnel-login 302`.
2. Complete the onboarding wizard once through the tunnel.

Nothing else is outstanding in this deployment; the non-blocking deferred
review minors are recorded in the M0 ledger and per-task reports
(`reports/2026-10-10-ohmzbudget-m0-foundation/` in the planning repo).

## Files
- `compose.yml` — services, volumes, secrets, networks, hardening.
- `docker-compose.override.yml` — pins the two adopted bridge subnets.
- `.env.example` — template for the untracked `.env` (non-secret deploy vars).
- `dc` — required entry point: sources `.env`, exports the secret files, runs compose.
- `bootstrap-secrets.sh` — writes/re-homes secrets into `secrets/` (never prints a value).
- `backup.sh` / `restore-drill.sh` — nightly backup and the proven restore drill.
- `.env` and `secrets/` — untracked live state (never committed).

## Hardening
Every service runs `restart: unless-stopped`, `security_opt: ["no-new-privileges:true"]`,
`cap_drop: ["ALL"]` and a `mem_limit`, with only the entrypoint caps each image needs
re-added: `CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID` for the two postgres services,
`SETGID, SETUID` for redis/valkey (they start as root and `setpriv` into their user),
and the postgres set for `paperless` (its s6 init chowns/creates under the data volume).
`redis` is additionally `read_only` with a `/tmp` tmpfs. The app root stays writable
because the image writes several runtime paths; the isolation comes from dropped caps
and `no-new-privileges`. `deploy/dc exec -T web` is the service name (`web`, never `app`).

## First-run order
1. `cp -n .env.example .env`; edit `ADMIN_EMAIL` to the real owner address (blocking).
2. `./bootstrap-secrets.sh` (Task 3), then rotate the paperless token — see
   "Rotate the paperless API token" below.
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
- `./dc build web worker && ./dc up -d web worker` — rebuild after a code change.
- Never run raw `./dc config` (or `docker compose … config`) against the live
  deployment — it renders the resolved secret values into its output. Validate
  with `./dc config --services` or `./dc config --quiet` instead.

## Rotate the paperless API token
The container-shell invocation is the historical M2 runbook of record
(`reports/2026-10-10-ohmzbudget-m2-document-bridge/task-7-report.md`): inside
the `paperless` container, `/command/with-contenv python3 manage.py shell -c
"…"` re-mints the `ohmzbudget` account's DRF token and prints only the
`TOKENKEY=` line. The capture pattern, run from the repo root:

1. Rotate — write the minted key into `deploy/secrets/paperless_token` via a
   temp file: `umask 077`, write `deploy/secrets/paperless_token.tmp.$$`,
   `chmod 400`, then `mv -f` into place (a mode-400 file is not writable in
   place).
2. `deploy/dc up -d --force-recreate web worker` — the app reads the token file
   at module load, and a changed secret file does not change the compose config
   hash, so a plain `up -d` reports `Running` and both containers keep the old
   token.
3. Verify `200` (`401` = wrong token; `403` = the account lost its
   permissions), from the repo root:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Token $(cat deploy/secrets/paperless_token)" \
     http://127.0.0.1:7301/api/documents/
   ```

Never print the token; record only size and shape (`41 B` = 40 hex chars + a
newline).

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

Both published ports are bound to loopback only — the app on `127.0.0.1:7300`
and paperless on `127.0.0.1:7301`; nothing binds `0.0.0.0`, so the edge is the
only way in. The owner sets the live hostname in untracked `deploy/.env` as
`TUNNEL_HOST` (never a tracked file) for the probes:

```bash
cd ~/StudioProjects/OhmzBudget
set -a; . deploy/.env; set +a          # TUNNEL_HOST is the untracked live value
curl -fsS -o /dev/null -w 'local   %{http_code}\n' http://127.0.0.1:7300/up   # 200
curl -fsS -o /dev/null -w 'tunnel  %{http_code}\n' "https://$TUNNEL_HOST/up"  # 200
ss -ltn | grep -E '(0\.0\.0\.0|\[::\]):(7300|7301)\b' && echo "EXPOSED ON 0.0.0.0 — stop" || echo "loopback only"
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
`deploy/backup.sh` (mode 0755, cron-driven) writes four timestamped artifacts into
`$BACKUP_DIR` and prunes the set:

- `sure_db_<ts>.sql.gz` — `pg_dump` of the app database (`db` container, local socket).
- `paperless_db_<ts>.sql.gz` — `pg_dump` of the paperless database (`paperless-db`).
- `app-storage_<ts>.tgz` — the `ohmzbudget_app-storage` volume (Active Storage attachments, incl. the paperless staging dir).
- `paperless-media_<ts>.tgz` — the `ohmzbudget_paperless-media` volume (document files).

`<ts>` is `date +%Y-%m-%d_%H%M%S`; the run uses one timestamp for all four files.
`BACKUP_DIR` must be set in the untracked `deploy/.env` — the script hard-requires
it and aborts with `set BACKUP_DIR in deploy/.env` when it is unset; this
deployment uses `/home/ohmz/ohmzbudget-backups/backups`. `BACKUP_KEEP_DAYS`
(default `14`) comes from the same file; artifacts older than `BACKUP_KEEP_DAYS`
are deleted (`find … -mtime +N -delete`, which also sweeps stray `*.part` files
and the dot-named `.*.sql` dump temps). The four names are fixed (consumed by
the restore drill and, later, the M5 monitor).

Each database dump goes to a temp file, is verified (`pg_dump` exit status plus a
`PostgreSQL database dump` marker) and only then published to the fixed name via
a `.part` file and an atomic rename, so a failed `pg_dump` never leaves a
valid-looking `.sql.gz` for the restore drill or the M5 monitor to trust. The two
volume archives get the same verify-before-publish rule: each is written to a
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
17 3 * * * /home/ohmz/StudioProjects/OhmzBudget/deploy/backup.sh >> /home/ohmz/ohmzbudget-backups/backup.log 2>&1
```

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

- Picks the newest `sure_db_*.sql.gz`, `app-storage_*.tgz`,
  `paperless_db_*.sql.gz` and `paperless-media_*.tgz` from `$BACKUP_DIR`
  (a missing app dump or storage archive aborts up front).
- `DROP DATABASE IF EXISTS` / `CREATE DATABASE ohmzbudget_restore_drill`, then
  loads the gzipped dump into it with `psql`.
- Compares `entries` **and** `users` row counts, live vs restored; they must be
  equal, and restored `users` must be `>= 1` (an empty dump cannot pass).
- Lists the first 5 entries of the storage archive, and of the
  paperless-media archive when one exists (`|| true` guards the `head` SIGPIPE
  that would otherwise trip `set -euo pipefail` as archives grow).
- `gunzip -t` verifies the paperless-db dump when one exists.
- `DROP DATABASE ohmzbudget_restore_drill` — no scratch database is left behind.
- Prints `restore drill OK` and exits `0`.

Each run writes only to `ohmzbudget_restore_drill`; the live `sure_production`
database is read for the comparison counts and otherwise untouched. The drill is
the verification for the backup set, so run it after enabling cron and after any
schema or backup change.

## §16.8 decision
The paperless consume folder stays enabled (paperless default) on the
`paperless-consume` named volume; it is unused — the M1 ingest path is the API.

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
