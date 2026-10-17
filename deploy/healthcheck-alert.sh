#!/bin/sh
# deploy/healthcheck-alert.sh — container, disk and backup-freshness monitor for
# the sure stack. Runs from the host (cron/systemd timer). Prints no secret
# values. Exits 0 when healthy, 1 after posting one alert.
set -eu

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
# Cron gives the script no environment; M0's backup.sh is the house pattern.
# Without this the ${ALERT_WEBHOOK_URL:?} guard below aborts under cron and the
# monitor silently posts nothing — the exact failure this task exists to close.
if [ -f "$DEPLOY_DIR/.env" ]; then
  # (Ruling P-m5-1, 2026-10-10 pre-flight) Caller overrides must survive the
  # source, or Steps 5/7 and T7 step 11 read .env's fresh BACKUP_DIR and the
  # real webhook and can never go RED.
  _caller_backup_dir="${BACKUP_DIR:-}"; _caller_alert_url="${ALERT_WEBHOOK_URL:-}"
  set -a; . "$DEPLOY_DIR/.env"; set +a
  [ -n "$_caller_backup_dir" ] && BACKUP_DIR="$_caller_backup_dir"
  [ -n "$_caller_alert_url" ] && ALERT_WEBHOOK_URL="$_caller_alert_url"
fi
DC="$DEPLOY_DIR/dc"

ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:?set ALERT_WEBHOOK_URL in deploy/.env}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/sure-backups/backups}"
DISK_MOUNT="${DISK_MOUNT:-/}"
DISK_LIMIT_PCT="${DISK_LIMIT_PCT:-90}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-26}"

fail=0
reasons=""

# 1. Every service in the current stack is running and healthy. We match on the
#    compose SERVICE name ({{.Service}}), not the container name: stopped ORPHAN
#    containers from a removed service (the paperless trio that Ruling R23 leaves
#    on disk) still appear under `ps -a` and must NOT be reported as failures.
#    `-a` is load-bearing: without it an exited app container would simply vanish
#    and its service would read as missing. A container that carries no
#    healthcheck reports a blank health and is accepted if Running.
if ! ps_out="$("$DC" ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)"; then
  fail=1; reasons="$reasons compose-unreadable"
else
  ok="$(printf '%s\n' "$ps_out" | awk '$2 == "running" && ($3 == "" || $3 == "healthy") {print $1}')"
  # (Ruling P-m5-3, 2026-10-10 pre-flight) A fully-removed project prints nothing
  # above and would pass; assert every expected service is present and healthy.
  # `ocr` reports health from its own /healthz healthcheck (compose). An `ollama`
  # service, when the owner adds one, can be appended to this list.
  for svc in web worker worker-heavy db redis ocr; do
    printf '%s\n' "$ok" | grep -qx -- "$svc" || { fail=1; reasons="$reasons not_ok=$svc"; }
  done
fi

# 2. Headroom on the volume host mount.
used_pct="$(df -P "$DISK_MOUNT" | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [ "${used_pct:-0}" -ge "$DISK_LIMIT_PCT" ]; then
  fail=1; reasons="$reasons disk=${used_pct}%>=${DISK_LIMIT_PCT}%"
fi

# 3. The newest of each backup artifact must be newer than BACKUP_MAX_AGE_HOURS.
#    With paperless gone the app-storage archive — which carries the document
#    store — is the only copy of every uploaded original.
for glob in 'sure_db_*.sql.gz' 'app-storage_*.tgz'; do
  fresh="$(find "$BACKUP_DIR" -name "$glob" -mmin "-$((BACKUP_MAX_AGE_HOURS * 60))" 2>/dev/null | head -n1 || true)"
  [ -n "$fresh" ] || { fail=1; reasons="$reasons backup_stale=$glob"; }
done

# 4. The document pipeline. An exhausted read is a user-visible failure no
#    automatic path can clear; a backed-up heavy lane means documents are
#    waiting behind a stalled reader; a stale reaper means the one path that
#    resumes a killed read has stopped running. Each is silent without this.
POSTGRES_USER="${POSTGRES_USER:-sure_user}"
POSTGRES_DB="${POSTGRES_DB:-sure_production}"
HEAVY_QUEUE_MAX="${HEAVY_QUEUE_MAX:-15}"
REAPER_MAX_AGE_MINUTES="${REAPER_MAX_AGE_MINUTES:-20}"

exhausted="$("$DC" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select count(*) from document_links where failure_code = 'retry_exhausted' and deleted_at is null" \
  2>/dev/null | tr -d '[:space:]')"
if [ -z "$exhausted" ]; then
  fail=1; reasons="$reasons document_health_unreadable"
elif [ "$exhausted" -gt 0 ]; then
  fail=1; reasons="$reasons documents_exhausted=$exhausted"
fi

# Sidekiq names each queue's list queue:<name>; DocumentUnderstandingJob runs
# on the heavy lane (config/sidekiq.yml).
heavy="$("$DC" exec -T redis redis-cli LLEN queue:heavy 2>/dev/null | tr -d '[:space:]')"
if [ -z "$heavy" ]; then
  fail=1; reasons="$reasons redis_unreadable"
elif [ "$heavy" -gt "$HEAVY_QUEUE_MAX" ]; then
  fail=1; reasons="$reasons heavy_queue_backlog=$heavy"
fi

# DocumentReaperJob writes this key after every sweep (every five minutes).
last_run="$("$DC" exec -T redis redis-cli GET sure:document_reaper:last_run 2>/dev/null | tr -d '[:space:]')"
if [ -z "$last_run" ]; then
  fail=1; reasons="$reasons reaper_never_ran"
elif [ "$last_run" -lt "$(( $(date +%s) - REAPER_MAX_AGE_MINUTES * 60 ))" ]; then
  fail=1; reasons="$reasons reaper_stale=${REAPER_MAX_AGE_MINUTES}m"
fi

if [ "$fail" -eq 1 ]; then
  printf 'sure healthcheck FAIL:%s\n' "$reasons" >&2
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"sure healthcheck FAIL:${reasons}\"}" \
    "$ALERT_WEBHOOK_URL" >/dev/null || true
  exit 1
fi

printf 'sure healthcheck OK (containers healthy, disk %s%%, backups fresh, documents drained)\n' "$used_pct"
