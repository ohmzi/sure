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

## §16.8 decision
The paperless consume folder stays enabled (paperless default) on the
`paperless-consume` named volume; it is unused — the M1 ingest path is the API.
