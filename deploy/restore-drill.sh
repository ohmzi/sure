#!/usr/bin/env bash
# Proven restore: load the newest Sure dump into a scratch DB, compare row counts
# (entries + users), list the app-storage archive and assert the document store
# survived inside it, then drop the scratch DB. Exits non-zero on ANY mismatch.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "deploy/.env missing" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${BACKUP_DIR:?set BACKUP_DIR in deploy/.env}"
: "${POSTGRES_USER:=sure_user}"
: "${POSTGRES_DB:=sure_production}"

SCRATCH="sure_restore_drill"
DUMP="$(ls -1t "$BACKUP_DIR"/sure_db_*.sql.gz 2>/dev/null | head -1 || true)"
STORAGE="$(ls -1t "$BACKUP_DIR"/app-storage_*.tgz 2>/dev/null | head -1 || true)"
[ -n "$DUMP" ] || { echo "no dump found in $BACKUP_DIR" >&2; exit 1; }
[ -n "$STORAGE" ] || { echo "no storage archive found in $BACKUP_DIR" >&2; exit 1; }

psql_live() { ./dc exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
psql_scratch() { ./dc exec -T db psql -U "$POSTGRES_USER" -d "$SCRATCH" -tAc "$1"; }

echo "drilling from: $DUMP"
./dc exec -T db psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS $SCRATCH;"
./dc exec -T db psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE $SCRATCH;"

gunzip -c "$DUMP" | ./dc exec -T db psql -q -U "$POSTGRES_USER" -d "$SCRATCH"

for t in entries users; do
  live="$(psql_live "select count(*) from $t;")"
  restored="$(psql_scratch "select count(*) from $t;")"
  echo "$t: live=$live restored=$restored"
  [ "$live" = "$restored" ] || { echo "MISMATCH: $t live=$live restored=$restored" >&2; exit 1; }
done
[ "$(psql_scratch 'select count(*) from users;')" -ge 1 ] \
  || { echo "restore drill loaded zero users — the dump is not a real restore" >&2; exit 1; }

echo "storage archive listing (first 5 entries):"
# `|| true` on each listing: alpine tar gets SIGPIPE once `head` exits, and the
# script runs under `set -euo pipefail` — without it the drill dies here as
# archives grow (the archives start near-empty, so this only bites later).
docker run --rm -v "$BACKUP_DIR":/backup:ro alpine:3.20 tar tzf "/backup/$(basename "$STORAGE")" | head -5 || true

# The document store lives inside the app-storage volume
# (/rails/storage/paperless-staged). Assert it is really in the archive — with
# paperless gone this volume is the only copy of every uploaded original, so a
# backup set without it is not a backup of the documents.
DOC_STORE="paperless-staged"
doc_entries="$(docker run --rm -v "$BACKUP_DIR":/backup:ro alpine:3.20 \
  tar tzf "/backup/$(basename "$STORAGE")" 2>/dev/null | grep -c "/${DOC_STORE}/" || true)"
echo "document store ($DOC_STORE) entries in the archive: $doc_entries"
[ "${doc_entries:-0}" -ge 1 ] \
  || { echo "MISMATCH: document store /${DOC_STORE}/ is missing from the app-storage archive" >&2; exit 1; }

./dc exec -T db psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE $SCRATCH;"
echo "restore drill OK"
