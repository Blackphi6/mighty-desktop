#!/usr/bin/env bash
# mighty.app 用: mlx_lm.server + anthropic_proxy をバックグラウンドで起動するだけ(claude CLIは起動しない)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${MODEL_DIR:-$DIR/models/heretic-9b-mlx-4bit}"
MLX_PORT="${MLX_PORT:-8081}"
PROXY_PORT="${PROXY_PORT:-8082}"
STATE="$DIR/.state"; mkdir -p "$STATE"
PY="${PYTHON:-$DIR/.venv/bin/python}"

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

[[ -f "$MODEL_DIR/config.json" ]] || { echo "Model not found: $MODEL_DIR" >&2; exit 1; }

if ! alive "$STATE/mlx.pid"; then
  nohup "$PY" -m mlx_lm server --model "$MODEL_DIR" --host 127.0.0.1 --port "$MLX_PORT" \
    --temp 0.6 --top-p 0.95 --max-tokens 8192 --prompt-cache-size 4 \
    >"$STATE/mlx.log" 2>&1 &
  echo $! >"$STATE/mlx.pid"
fi

if ! alive "$STATE/proxy.pid"; then
  GUARD="${GUARD:-block}" GUARD_LOG="$STATE/guard.log" BACKEND_URL="http://127.0.0.1:$MLX_PORT" BACKEND_MODEL="$MODEL_DIR" PROXY_PORT="$PROXY_PORT" \
    nohup "$PY" "$DIR/anthropic_proxy.py" >"$STATE/proxy.log" 2>&1 &
  echo $! >"$STATE/proxy.pid"
fi

for i in $(seq 1 300); do
  curl -sf "http://127.0.0.1:$MLX_PORT/v1/models" >/dev/null 2>&1 && curl -sf "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1 && exit 0
  alive "$STATE/mlx.pid" || { echo "mlx_lm.server crashed. Log: $STATE/mlx.log" >&2; exit 1; }
  sleep 1
done
echo "timeout waiting for backend" >&2
exit 1
