#!/usr/bin/env bash
# Generate/re-home the Sure deploy secrets into deploy/secrets/.
# Never prints a secret value — only file paths and sizes.
set -euo pipefail
cd "$(dirname "$0")"

umask 077
mkdir -p secrets
chmod 700 secrets

write_secret() {           # write_secret <name> < value-on-stdin
  local f="secrets/$1"
  if [ -s "$f" ]; then
    # Drain stdin before returning: the callers pipe into this function, and
    # returning without reading gives the upstream `tr`/`openssl` SIGPIPE —
    # under `set -o pipefail` that aborts the whole script (exit 141) at the
    # FIRST kept file, so a later re-run that needs to recover a missing
    # secret would silently skip everything after it.
    cat >/dev/null
    echo "keep  $f"
    return
  fi
  local t="$f.tmp.$$"
  cat > "$t"
  chmod 400 "$t"
  mv -f "$t" "$f"          # mv needs only directory write, even onto a mode-400 file
  echo "write $f ($(wc -c < "$f") B)"
}

# Fresh, unique secrets (never the public compose default).
openssl rand -hex 64  | tr -d '\n' | write_secret secret_key_base
openssl rand -base64 36 | tr -d '\n' | write_secret postgres_password
openssl rand -base64 24 | tr -d '\n' | write_secret admin_password

echo "done. no secret values were printed."
