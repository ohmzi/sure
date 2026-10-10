#!/usr/bin/env bash
# Generate/re-home the OhmzBudget deploy secrets into deploy/secrets/.
# Never prints a secret value — only file paths and sizes.
set -euo pipefail
cd "$(dirname "$0")"

umask 077
mkdir -p secrets
chmod 700 secrets

write_secret() {           # write_secret <name> < value-on-stdin
  local f="secrets/$1"
  if [ -s "$f" ]; then echo "keep  $f"; return; fi
  local t="$f.tmp.$$"
  cat > "$t"
  chmod 400 "$t"
  mv -f "$t" "$f"          # mv needs only directory write, even onto a mode-400 file
  echo "write $f ($(wc -c < "$f") B)"
}

recover_secret() {         # recover_secret <name> <source-path>
  local f="secrets/$1" src="$2"
  [ -s "$f" ] && { echo "keep  $f"; return; }
  [ -s "$src" ] || { echo "missing recovery source: $src" >&2; exit 1; }
  local t="$f.tmp.$$"
  cp --no-preserve=mode "$src" "$t"
  chmod 400 "$t"
  mv -f "$t" "$f"
  echo "recover $f ($(wc -c < "$f") B)"
}

# 1. Fresh, unique secrets (never the public compose default).
openssl rand -hex 64  | tr -d '\n' | write_secret secret_key_base
openssl rand -base64 36 | tr -d '\n' | write_secret postgres_password
openssl rand -base64 24 | tr -d '\n' | write_secret admin_password

# 2. Re-home the recovered paperless secret key (never printed).
recover_secret paperless_secret_key "$HOME/ohmzbudget-backups/paperless_secret_key.recovered"

# 3. Recover the paperless DB password from the RUNNING container before any
#    recreate. The named postgres volume is already initialised with it.
if [ ! -s secrets/paperless_db_password ]; then
  t="secrets/paperless_db_password.tmp.$$"
  docker inspect paperless-db --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^POSTGRES_PASSWORD=//p' > "$t"
  chmod 400 "$t"
  mv -f "$t" secrets/paperless_db_password
  echo "recover secrets/paperless_db_password ($(wc -c < secrets/paperless_db_password) B)"
else
  echo "keep  secrets/paperless_db_password"
fi

echo "done. no secret values were printed."
