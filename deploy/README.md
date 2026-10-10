# OhmzBudget deploy

Compose project `ohmzbudget`: the Rails app (`web`, `worker`) and the re-adopted
paperless-ngx sidecar (`paperless`, `paperless-db`, `paperless-valkey`).

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
2. `./bootstrap-secrets.sh` (Task 3), then rotate the paperless token (Task 4).
3. `./dc up -d --build`, then `./dc exec -T web ./bin/rails ohmzbudget:first_run`.
4. `http://127.0.0.1:7300/up` answers 200; log in with the admin email.

## Everyday commands
- `./dc ps` / `./dc logs -f web` — status and logs.
- `./dc build web worker && ./dc up -d web worker` — rebuild after a code change.

## Backups
`deploy/backup.sh` (mode 0755, cron-driven) writes four timestamped artifacts into
`$BACKUP_DIR` and prunes the set:

- `sure_db_<ts>.sql.gz` — `pg_dump` of the app database (`db` container, local socket).
- `paperless_db_<ts>.sql.gz` — `pg_dump` of the paperless database (`paperless-db`).
- `app-storage_<ts>.tgz` — the `ohmzbudget_app-storage` volume (Active Storage attachments, incl. the paperless staging dir).
- `paperless-media_<ts>.tgz` — the `ohmzbudget_paperless-media` volume (document files).

`<ts>` is `date +%Y-%m-%d_%H%M%S`; the run uses one timestamp for all four files.
`BACKUP_DIR` (default `$HOME/ohmzbudget-backups/backups`) and `BACKUP_KEEP_DAYS`
(default `14`) come from the untracked `deploy/.env`; artifacts older than
`BACKUP_KEEP_DAYS` are deleted (`find … -mtime +N -delete`, which also sweeps
stray `*.part` files). The four names are fixed (consumed by the restore drill
and, later, the M5 monitor).

Each database dump goes to a temp file, is verified (`pg_dump` exit status plus a
`PostgreSQL database dump` marker) and only then published to the fixed name via
a `.part` file and an atomic rename, so a failed `pg_dump` never leaves a
valid-looking `.sql.gz` for the restore drill or the M5 monitor to trust. Run it
by hand with `./backup.sh`; if a dump fails the run aborts (non-zero exit) and is
logged (`backup FAILED: …`) on stderr, but it may leave no usable backup for that
run.

Host crontab entry (03:17 — off the top of the hour; the log lives under the
owner's backup root, not `/var/log`):

```cron
17 3 * * * /home/ohmz/StudioProjects/OhmzBudget/deploy/backup.sh >> /home/ohmz/ohmzbudget-backups/backup.log 2>&1
```

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
