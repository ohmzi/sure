#!/usr/bin/env bash
# Nightly backup: Sure DB + paperless DB dumps + Active Storage + paperless media volumes.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "deploy/.env missing" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${BACKUP_DIR:?set BACKUP_DIR in deploy/.env}"
: "${POSTGRES_USER:=sure_user}"
: "${POSTGRES_DB:=sure_production}"
: "${PAPERLESS_DBUSER:=paperless}"
: "${PAPERLESS_DBNAME:=paperless}"
: "${BACKUP_KEEP_DAYS:=14}"

mkdir -p "$BACKUP_DIR"
TS="$(date +%Y-%m-%d_%H%M%S)"

# Database dumps go to a temp file, are VERIFIED, then published atomically.
# `pg_dump | gzip > target` must not be used: the shell creates the target at
# pipeline start and gzip finalizes a CRC-valid stream even when pg_dump failed,
# so a failed run would leave a valid-looking, empty-member .sql.gz at the exact
# expected name — and the M5 monitor and the restore drill pick the newest file
# by name/mtime, i.e. they would trust a corrupt backup for BACKUP_KEEP_DAYS.
# Nothing may exist at the fixed name unless the dump verified.
dump_db() {   # dump_db <service> <user> <dbname> <target>
  local service="$1" user="$2" dbname="$3" target="$4"
  local tmp="$BACKUP_DIR/.$TS.$$.sql"
  if ! ./dc exec -T "$service" pg_dump -U "$user" "$dbname" > "$tmp"; then
    rm -f "$tmp"; echo "backup FAILED: $service dump did not complete" >&2; exit 1
  fi
  if [ ! -s "$tmp" ] || ! grep -q 'PostgreSQL database dump' "$tmp"; then
    rm -f "$tmp"; echo "backup FAILED: $service dump is empty or not a pg_dump" >&2; exit 1
  fi
  gzip -c "$tmp" > "$target.part" && mv -f "$target.part" "$target"
  rm -f "$tmp"
}

# 1. Sure database (pg_dump inside the db container; local socket auth needs no password)
dump_db db "$POSTGRES_USER" "$POSTGRES_DB" "$BACKUP_DIR/sure_db_$TS.sql.gz"

# 2. paperless database (the document engine's metadata)
dump_db paperless-db "$PAPERLESS_DBUSER" "$PAPERLESS_DBNAME" "$BACKUP_DIR/paperless_db_$TS.sql.gz"

# Volume archives get the SAME verify-before-publish rule as the DB dumps:
# a tar that fails on an unreadable member still closes gzip cleanly, so a
# direct `tar czf` at the fixed name would leave a gzip-valid but INCOMPLETE
# archive that the drill and the monitor would trust.
archive_volume() {   # archive_volume <volume> <target>
  local volume="$1" target="$2"
  local part="$target.part"
  if ! docker run --rm -v "$volume":/data:ro -v "$BACKUP_DIR":/backup alpine:3.20 \
       tar czf "/backup/$(basename "$part")" -C /data .; then
    rm -f "$part"; echo "backup FAILED: $volume archive did not complete" >&2; exit 1
  fi
  if ! gzip -t "$part"; then
    rm -f "$part"; echo "backup FAILED: $volume archive is not valid gzip" >&2; exit 1
  fi
  mv -f "$part" "$target"
}

# 3. Active Storage volume (attached documents)
archive_volume ohmzbudget_app-storage "$BACKUP_DIR/app-storage_$TS.tgz"

# 4. paperless media volume (the document files)
archive_volume ohmzbudget_paperless-media "$BACKUP_DIR/paperless-media_$TS.tgz"

# Retention
find "$BACKUP_DIR" -type f \( -name '*.sql.gz' -o -name '*.tgz' -o -name '*.part' -o -name '.*.sql' \) -mtime +"$BACKUP_KEEP_DAYS" -delete

echo "backup complete: $TS -> $BACKUP_DIR"
