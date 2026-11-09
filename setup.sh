#!/usr/bin/env bash
# Download the model → convert to MLX 4-bit → register claude-local on PATH.
#   SRC_DIR=/Volumes/big/src ./setup.sh   # change where the ~19GB source goes (if disk is tight)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic"
SRC_DIR="${SRC_DIR:-$DIR/models/src}"
OUT="$DIR/models/heretic-9b-mlx-4bit"

command -v claude >/dev/null || { echo "claude (Claude Code) not found. Do step 1 of the README first." >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is required: brew install uv" >&2; exit 1; }

[[ -d "$DIR/.venv" ]] || uv venv "$DIR/.venv" --python 3.12
uv pip install --python "$DIR/.venv/bin/python" -U mlx-lm fastapi uvicorn httpx "huggingface_hub[cli]"

if [[ ! -f "$OUT/config.json" ]]; then
  mkdir -p "$SRC_DIR"
  echo "▶ Downloading (~19GB)"
  # model-mtp.safetensors (speculative decoding) is not needed
  "$DIR/.venv/bin/hf" download "$REPO" --exclude "model-mtp.safetensors" --local-dir "$SRC_DIR"
  echo "▶ Converting to MLX 4-bit"
  "$DIR/.venv/bin/python" "$DIR/convert_model.py" "$SRC_DIR" "$OUT"
  echo "The source is no longer needed; you can delete it: rm -rf \"$SRC_DIR\""
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$DIR/claude-local" "$HOME/.local/bin/claude-local"
echo "✔ Done. Run claude-local (~/.local/bin must be on PATH)"
