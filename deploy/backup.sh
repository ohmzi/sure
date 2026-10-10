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

# 1. Sure database (pg_dump inside the db container; local socket auth needs no password)
./dc exec -T db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$BACKUP_DIR/sure_db_$TS.sql.gz"

# 2. paperless database (the document engine's metadata)
./dc exec -T paperless-db pg_dump -U "$PAPERLESS_DBUSER" "$PAPERLESS_DBNAME" | gzip > "$BACKUP_DIR/paperless_db_$TS.sql.gz"

# 3. Active Storage volume (attached documents)
docker run --rm -v ohmzbudget_app-storage:/data:ro -v "$BACKUP_DIR":/backup alpine:3.20 \
  tar czf "/backup/app-storage_$TS.tgz" -C /data .

# 4. paperless media volume (the document files)
docker run --rm -v ohmzbudget_paperless-media:/data:ro -v "$BACKUP_DIR":/backup alpine:3.20 \
  tar czf "/backup/paperless-media_$TS.tgz" -C /data .

# Retention
find "$BACKUP_DIR" -type f \( -name '*.sql.gz' -o -name '*.tgz' \) -mtime +"$BACKUP_KEEP_DAYS" -delete

echo "backup complete: $TS -> $BACKUP_DIR"
