#!/usr/bin/env bash
# Sets up the local AI this deployment uses out of the box (compose.yml's
# LLM_PROVIDER=local): Ollama on THIS host, serving qwen3.5:9b to the app's
# containers through host.docker.internal.
#
# Why qwen3.5:9b (the owner's bake-off, 2026-10-19, through Sure's own code):
#   - it reads images AND calls tools; qwen2.5vl:7b cannot call tools, so the
#     AI assistant could not work at all (0/9 vs 9/9 on Sure's real tools);
#   - it read the June card statement at 125-132 of 133 rows and the RBC
#     chequing statement at 24 of 29, every amount exact (qwen2.5vl:7b: 3/133
#     and 13/29);
#   - it fits a 24 GB GPU with room to spare (~7.6 GB).
# Sure reads statements with its reasoning switched off (reasoning_effort
# "none"): with it on, a page took ~3 minutes and long reads came back empty.
#
# Idempotent: re-running changes nothing that is already in place.
set -euo pipefail

MODEL="${LOCAL_LLM_MODEL:-qwen3.5:9b}"
API="http://127.0.0.1:11434"

# The Ollama settings the app depends on:
#   OLLAMA_HOST            listen beyond loopback, or Docker cannot reach it
#                          (keep port 11434 firewalled from the LAN)
#   OLLAMA_CONTEXT_LENGTH  a statement page plus its answer needs ~8k tokens;
#                          the default context cuts it off
#   OLLAMA_KEEP_ALIVE      unload an idle model quickly so the GPU is freed
#   OLLAMA_FLASH_ATTENTION / OLLAMA_KV_CACHE_TYPE  less memory per request
#   OLLAMA_MAX_LOADED_MODELS  room for the reader beside other workloads
SETTINGS=(
  "OLLAMA_HOST=0.0.0.0:11434"
  "OLLAMA_CONTEXT_LENGTH=32768"
  "OLLAMA_KEEP_ALIVE=60s"
  "OLLAMA_FLASH_ATTENTION=1"
  "OLLAMA_KV_CACHE_TYPE=q8_0"
  "OLLAMA_MAX_LOADED_MODELS=3"
)

step() { printf '\n==> %s\n' "$*"; }

step "Ollama"
if ! command -v ollama >/dev/null 2>&1; then
  echo "Ollama is not installed. Install it, then run this script again:"
  echo "  curl -fsSL https://ollama.com/install.sh | sh"
  exit 1
fi
ollama --version

step "Ollama service settings"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
  current="$(systemctl show ollama -p Environment --value 2>/dev/null || true)"
  missing=()
  for setting in "${SETTINGS[@]}"; do
    [[ " $current " == *" $setting "* ]] || missing+=("$setting")
  done
  if ((${#missing[@]})); then
    echo "Adding to /etc/systemd/system/ollama.service.d/sure.conf (needs sudo):"
    printf '  %s\n' "${missing[@]}"
    {
      echo "[Service]"
      for setting in "${missing[@]}"; do echo "Environment=\"$setting\""; done
    } | sudo tee /etc/systemd/system/ollama.service.d/sure.conf >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
  else
    echo "Already set."
  fi
else
  echo "No systemd service found. Start Ollama with these in its environment:"
  printf '  %s\n' "${SETTINGS[@]}"
fi

step "Waiting for the Ollama API"
for _ in $(seq 1 30); do
  curl -fsS "$API/api/version" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$API/api/version" || { echo; echo "Ollama is not answering on $API." >&2; exit 1; }
echo

step "Model $MODEL"
ollama pull "$MODEL"

step "Capabilities"
capabilities="$(curl -fsS "$API/api/show" -d "{\"model\":\"$MODEL\"}" | tr -d '\n' | grep -o '"capabilities":\[[^]]*\]' || true)"
echo "${capabilities:-unknown}"
for needed in vision tools; do
  if [[ "$capabilities" != *"\"$needed\""* ]]; then
    echo "$MODEL does not report '$needed'. Sure needs vision to read documents and tools for the assistant." >&2
    exit 1
  fi
done

step "From the app's containers"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^sure-web-1$'; then
  if docker exec sure-web-1 curl -fsS -m 5 http://host.docker.internal:11434/api/version >/dev/null; then
    echo "Reachable from sure-web-1."
  else
    echo "sure-web-1 cannot reach Ollama: check OLLAMA_HOST and the host firewall for the Docker bridge." >&2
    exit 1
  fi
else
  echo "The app is not running yet; System health > AI status checks this once it is."
fi

cat <<TEXT

Done. The app uses $MODEL for the assistant and for reading documents
(compose.yml defaults LLM_PROVIDER=local and LOCAL_LLM_MODEL=$MODEL).
In the app, Settings > System health > AI status > "Load local model" warms it
up, and "Run checks again" confirms chat, tools and PDF reading.
TEXT
