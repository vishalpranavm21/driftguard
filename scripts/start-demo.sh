#!/usr/bin/env bash
# One command before class: cluster + registry up, AI engine (Ollama) up, dashboard up.
# Usage: bash scripts/start-demo.sh          start everything (safe to re-run)
#        bash scripts/start-demo.sh stop     stop the engine and the dashboard
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VENV=${VENV:-$HOME/.venvs/driftguard}
ENGINE_PORT=${ENGINE_PORT:-8088}     # 8080 is often taken by Jenkins
DASH_PORT=${DASH_PORT:-8090}
export ENGINE_URL="http://localhost:$ENGINE_PORT"

pid_on() { ss -ltnp 2>/dev/null | grep ":$1 " | grep -oP 'pid=\K[0-9]+' | head -1; }

if [ "${1:-}" = "stop" ]; then
  for p in $ENGINE_PORT $DASH_PORT; do P=$(pid_on $p); [ -n "$P" ] && kill "$P" && echo "stopped :$p"; done
  exit 0
fi

echo ">>> Cluster"
docker start k3d-dgreg >/dev/null 2>&1 || true
k3d cluster list 2>/dev/null | grep -q "^driftguard " || { echo "!!! cluster missing: run bash scripts/setup-cluster.sh"; exit 1; }
k3d cluster start driftguard >/dev/null 2>&1 || true
kubectl config use-context k3d-driftguard >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null && echo "    nodes Ready"
kubectl -n kyverno wait --for=condition=Available deploy --all --timeout=180s >/dev/null && echo "    Kyverno up"
kubectl -n flux-system wait --for=condition=Available deploy --all --timeout=180s >/dev/null && echo "    Flux up"

echo ">>> Python venv ($VENV)"
[ -x "$VENV/bin/uvicorn" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q fastapi uvicorn; }

echo ">>> Ollama"
curl -sf localhost:11434/api/tags | grep -q '"qwen2.5:3b"' && echo "    qwen2.5:3b available" \
  || echo "!!! Ollama not reachable or model missing (ollama pull qwen2.5:3b). The engine will fail closed (score 100)."

echo ">>> AI engine on :$ENGINE_PORT"
if curl -sf "$ENGINE_URL/healthz" >/dev/null; then
  echo "    already running"
else
  # setsid -f: fully detached, does not keep this script's stdout open
  DRIFTGUARD_LLM=${DRIFTGUARD_LLM:-ollama} OLLAMA_MODEL=${OLLAMA_MODEL:-qwen2.5:3b} \
    setsid -f "$VENV/bin/uvicorn" --app-dir "$ROOT/engine" app:app --host 127.0.0.1 --port "$ENGINE_PORT" \
    > /tmp/driftguard-engine.log 2>&1 < /dev/null
  for _ in $(seq 20); do curl -sf "$ENGINE_URL/healthz" >/dev/null && break; sleep 0.5; done
  curl -sf "$ENGINE_URL/healthz" >/dev/null || { echo "!!! engine failed, see /tmp/driftguard-engine.log"; exit 1; }
  echo "    started (log: /tmp/driftguard-engine.log)"
fi
echo "    $(curl -s "$ENGINE_URL/healthz")"
# warm up the model so the first button press in class is fast
curl -s --max-time 120 localhost:11434/api/generate -d '{"model":"qwen2.5:3b","prompt":"ok","stream":false,"options":{"num_predict":1}}' >/dev/null 2>&1 || true

echo ">>> Dashboard on :$DASH_PORT"
if curl -sf "http://localhost:$DASH_PORT/api/state" >/dev/null; then
  echo "    already running"
else
  setsid -f "$VENV/bin/uvicorn" --app-dir "$ROOT/dashboard" app:app --host 127.0.0.1 --port "$DASH_PORT" \
    > /tmp/driftguard-dashboard.log 2>&1 < /dev/null
  for _ in $(seq 20); do curl -sf "http://localhost:$DASH_PORT/api/state" >/dev/null && break; sleep 0.5; done
  curl -sf "http://localhost:$DASH_PORT/api/state" >/dev/null || { echo "!!! dashboard failed, see /tmp/driftguard-dashboard.log"; exit 1; }
  echo "    started (log: /tmp/driftguard-dashboard.log)"
fi

echo
echo "  DriftGuard control room:  http://localhost:$DASH_PORT"
echo "  Stop later with:          bash scripts/start-demo.sh stop"
