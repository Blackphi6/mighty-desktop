# mightyCode

Run **Claude Code** on a local MLX model
([DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic](https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic)).
No API key needed, fully local (Apple Silicon only).

```
claude  --/v1/messages-->  anthropic_proxy.py  --/v1/chat/completions-->  mlx_lm.server (4-bit model)
```

| File | Purpose |
|---|---|
| `claude-local` | Launcher. Starts the backend as a persistent service and opens `claude` |
| `anthropic_proxy.py` | Anthropic Messages API → OpenAI-compatible API proxy (streaming and tool calls supported) + EoCC compaction |
| `convert_model.py` | HF → MLX 4-bit conversion (quantizes on CPU) |
| `setup.sh` | Creates the venv, downloads and converts the model, registers the command on PATH |

## Requirements
- Apple Silicon Mac (macOS), 16 GB RAM or more recommended
- Free disk space: about **25 GB** during conversion (19 GB source + 4.7 GB output). About 5 GB once the source is deleted
- [uv](https://docs.astral.sh/uv/) (`brew install uv`)

## Installation

### 1. Claude Code itself (not included in this repository)
Claude Code cannot be redistributed, so install it yourself by following the official instructions.

```bash
# Official installer (macOS / Linux)
curl -fsSL https://claude.ai/install.sh | bash
# or via npm (Node.js 18+)
npm install -g @anthropic-ai/claude-code

claude --version   # verify
```
See https://code.claude.com/docs for the latest instructions. You do not need to log in with an Anthropic account to use it with a local model.

### 2. This repository
```bash
git clone https://github.com/shi3z/mightyCode.git
cd mightyCode
./setup.sh
```
If you are short on disk space, put the conversion source on an external drive: `SRC_DIR=/Volumes/big/src ./setup.sh`
(If `~/.local/bin` is not on your PATH, add `export PATH="$HOME/.local/bin:$PATH"`.)

## Usage
```bash
claude-local          # start (first run takes a few tens of seconds to load the model). Arguments are passed through to claude
claude-local -p "..." # non-interactive run
claude-local status   # backend status
claude-local logs     # tail the logs
claude-local stop     # stop the backend (it keeps running after claude exits, so stop it when you no longer need it)
```

Environment variables:
| Variable | Default | Description |
|---|---|---|
| `MODEL_DIR` | `models/heretic-9b-mlx-4bit` | MLX model to use |
| `MLX_PORT` / `PROXY_PORT` | 8080 / 8082 | Ports |
| `THINKING` | 0 | Set to 1 to enable Qwen's thinking mode (slower) |
| `COMPACT_THRESHOLD` | 48000 | Estimated token count that triggers EoCC compaction (0 disables it) |
| `MAX_TOKENS_CAP` | 8192 | Maximum output tokens per response |

## EoCC (End-of-Conversation Compaction)
Based on [arXiv:2611.05306 "You don't need long context"](https://arxiv.org/abs/2611.05306). When the context exceeds a threshold,
the model itself writes a recap for resuming (objective, established facts, changes made, dead ends, next step).
From then on only "original task + recap + later turns" is sent, which keeps the history short
(less KV-cache memory and lower decode latency).
Claude Code's own system prompt and tool definitions take about 15–20K tokens, so the threshold is set high (48K).
The paper's results were measured on API models; the effect on a local 9B model is untested.

## Known caveats
- Image input is not supported (images are omitted)
- A warning like `Claude Code doesn't recognize the model "heretic-9b-local"` appears; it does not affect operation
- Converting on the GPU hit a Metal `GPU Timeout Error` on some setups, so conversion runs on the CPU
- With the system mlx-lm 0.31.1 and mlx 0.32, `mlx_lm.server` crashed, so a dedicated venv with the latest mlx-lm is installed
- This is a 9B model; quality on complex agentic work is far below the real Claude
- This model is an uncensored variant. Use it at your own risk
