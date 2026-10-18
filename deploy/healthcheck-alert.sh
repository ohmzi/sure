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
# A read or an import that has not moved past these bounds is no longer just
# slow: the reaper/sweeper that resumes it is not running, or the job was lost.
# A held document (failure_message set) is waiting on a person and is excluded
# from the stall check on purpose. Import.clean reaps importing/reverting rows
# after 6 hours, so 90 minutes is an early warning, not a duplicate reaper.
DOCUMENT_STALL_MAX_MINUTES="${DOCUMENT_STALL_MAX_MINUTES:-60}"
IMPORT_STUCK_MAX_MINUTES="${IMPORT_STUCK_MAX_MINUTES:-90}"
# The recorded LLM provider failure share. LlmUsage stores a failed call with
# metadata.error, so this is a real rate over a real denominator; local
# providers that record no usage simply leave the sample too small to judge.
LLM_ERROR_RATE_MAX="${LLM_ERROR_RATE_MAX:-50}"
LLM_ERROR_WINDOW_MINUTES="${LLM_ERROR_WINDOW_MINUTES:-60}"
LLM_ERROR_MIN_CALLS="${LLM_ERROR_MIN_CALLS:-5}"
case "$DOCUMENT_STALL_MAX_MINUTES" in ''|*[!0-9]*) DOCUMENT_STALL_MAX_MINUTES=60 ;; esac
case "$IMPORT_STUCK_MAX_MINUTES" in ''|*[!0-9]*) IMPORT_STUCK_MAX_MINUTES=90 ;; esac
case "$LLM_ERROR_RATE_MAX" in ''|*[!0-9]*) LLM_ERROR_RATE_MAX=50 ;; esac
case "$LLM_ERROR_WINDOW_MINUTES" in ''|*[!0-9]*) LLM_ERROR_WINDOW_MINUTES=60 ;; esac
case "$LLM_ERROR_MIN_CALLS" in ''|*[!0-9]*) LLM_ERROR_MIN_CALLS=5 ;; esac

# Sidekiq's keys live in the database REDIS_URL selects. This stack sets
# redis://redis:6379/1 in compose.yml, but redis-cli defaults to db 0 — without
# -n the heavy-queue and reaper reads silently look in the wrong database.
# Derive the index from REDIS_URL when the caller/.env supplies it, falling
# back to the value compose.yml declares for this deployment.
REDIS_URL="${REDIS_URL:-$(sed -n 's/^[[:space:]]*REDIS_URL:[[:space:]]*"\([^"]*\)".*/\1/p' "$DEPLOY_DIR/compose.yml" 2>/dev/null | head -n1)}"
REDIS_DB=1
case "${REDIS_URL##*/}" in
  ''|*[!0-9]*) ;;
  *) REDIS_DB="${REDIS_URL##*/}" ;;
esac

exhausted="$("$DC" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select count(*) from document_links where failure_code = 'retry_exhausted' and deleted_at is null" \
  2>/dev/null | tr -d '[:space:]')"
if [ -z "$exhausted" ]; then
  fail=1; reasons="$reasons document_health_unreadable"
elif [ "$exhausted" -gt 0 ]; then
  fail=1; reasons="$reasons documents_exhausted=$exhausted"
fi

# 5. A read that is still queued/processing past its lease and the reaper's
#    grace window means nothing is resuming it. Held rows carry a failure
#    message and are waiting on a person, so they are not a stall.
stalled_docs="$("$DC" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select count(*) from document_links where deleted_at is null and status in ('queued', 'processing') and stored_path is not null and failure_message is null and updated_at < now() - interval '${DOCUMENT_STALL_MAX_MINUTES} minutes'" \
  2>/dev/null | tr -d '[:space:]')"
if [ -z "$stalled_docs" ]; then
  fail=1; reasons="$reasons document_health_unreadable"
elif [ "$stalled_docs" -gt 0 ]; then
  fail=1; reasons="$reasons documents_stalled=$stalled_docs"
fi

# 6. An import still job-owned past the bound means its worker died and the
#    sweeper has not reconciled it. Import.clean handles the 6-hour case; this
#    catches the wedge much earlier.
stuck_imports="$("$DC" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select count(*) from imports where status in ('importing', 'reverting') and updated_at < now() - interval '${IMPORT_STUCK_MAX_MINUTES} minutes'" \
  2>/dev/null | tr -d '[:space:]')"
if [ -z "$stuck_imports" ]; then
  fail=1; reasons="$reasons imports_unreadable"
elif [ "$stuck_imports" -gt 0 ]; then
  fail=1; reasons="$reasons imports_stuck=$stuck_imports"
fi

# 7. The recorded LLM provider failure share. LlmUsage has both sides of the
#    ratio (a successful call's tokens, a failed call's metadata.error), so a
#    small sample is skipped rather than reported as a false 100%. The
#    predicate matches OperatorMetrics: a present-but-null error is not counted.
llm_counts="$("$DC" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select count(*) filter (where metadata ->> 'error' is not null), count(*) from llm_usages where created_at > now() - interval '${LLM_ERROR_WINDOW_MINUTES} minutes'" \
  2>/dev/null | tr -d '[:space:]')"
llm_failed="${llm_counts%%|*}"
llm_total="${llm_counts##*|}"
if [ -z "$llm_counts" ] || [ "$llm_failed" = "$llm_counts" ]; then
  fail=1; reasons="$reasons llm_usage_unreadable"
elif [ "$llm_total" -ge "$LLM_ERROR_MIN_CALLS" ]; then
  llm_rate=$(( llm_failed * 100 / llm_total ))
  if [ "$llm_rate" -ge "$LLM_ERROR_RATE_MAX" ]; then
    fail=1; reasons="$reasons llm_error_rate=${llm_rate}%>=${LLM_ERROR_RATE_MAX}%"
  fi
fi

# Sidekiq names each queue's list queue:<name>; DocumentUnderstandingJob runs
# on the heavy lane (config/sidekiq.yml).
heavy="$("$DC" exec -T redis redis-cli -n "$REDIS_DB" LLEN queue:heavy 2>/dev/null | tr -d '[:space:]')"
if [ -z "$heavy" ]; then
  fail=1; reasons="$reasons redis_unreadable"
elif [ "$heavy" -gt "$HEAVY_QUEUE_MAX" ]; then
  fail=1; reasons="$reasons heavy_queue_backlog=$heavy"
fi

# DocumentReaperJob writes this key after every sweep (every five minutes).
last_run="$("$DC" exec -T redis redis-cli -n "$REDIS_DB" GET sure:document_reaper:last_run 2>/dev/null | tr -d '[:space:]')"
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
