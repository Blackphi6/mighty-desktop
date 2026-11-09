#!/usr/bin/env bash
# モデルのダウンロード → MLX 4bit 変換 → claude-local のPATH登録 までを行う。
#   SRC_DIR=/Volumes/big/src ./setup.sh   # 変換元(約19GB)の置き場を変える(ディスクが足りない時)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic"
SRC_DIR="${SRC_DIR:-$DIR/models/src}"
OUT="$DIR/models/heretic-9b-mlx-4bit"

command -v claude >/dev/null || { echo "claude (Claude Code) が見つかりません。README の手順1を先に実施してください。" >&2; exit 1; }
command -v uv >/dev/null || { echo "uv が必要です: brew install uv" >&2; exit 1; }

[[ -d "$DIR/.venv" ]] || uv venv "$DIR/.venv" --python 3.12
uv pip install --python "$DIR/.venv/bin/python" -U mlx-lm fastapi uvicorn httpx "huggingface_hub[cli]"

if [[ ! -f "$OUT/config.json" ]]; then
  mkdir -p "$SRC_DIR"
  echo "▶ ダウンロード (約19GB)"
  # model-mtp.safetensors(投機デコード用)は不要
  "$DIR/.venv/bin/hf" download "$REPO" --exclude "model-mtp.safetensors" --local-dir "$SRC_DIR"
  echo "▶ MLX 4bit へ変換"
  "$DIR/.venv/bin/python" "$DIR/convert_model.py" "$SRC_DIR" "$OUT"
  echo "変換元は不要なので削除できます: rm -rf \"$SRC_DIR\""
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$DIR/claude-local" "$HOME/.local/bin/claude-local"
echo "✔ 完了。 claude-local で起動 (PATH に ~/.local/bin が必要)"
