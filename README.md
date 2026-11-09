# mightyCode

ローカルの MLX モデル([DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic](https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic))を
バックエンドにして **Claude Code** を動かすための一式。API キー不要・完全ローカル(Apple Silicon 専用)。

```
claude  --/v1/messages-->  anthropic_proxy.py  --/v1/chat/completions-->  mlx_lm.server (4bit モデル)
```

| ファイル | 役割 |
|---|---|
| `claude-local` | 起動コマンド。バックエンドを常駐起動して `claude` を開く |
| `anthropic_proxy.py` | Anthropic Messages API → OpenAI 互換 API の変換プロキシ(ストリーミング/ツール呼び出し対応) + EoCC 圧縮 |
| `convert_model.py` | HF → MLX 4bit 変換(CPU 量子化) |
| `setup.sh` | venv 作成・モデル取得・変換・PATH 登録 |

## 必要環境
- Apple Silicon Mac(macOS)、メモリ 16GB 以上推奨
- 空きディスク: 変換中は約 **25GB**(変換元 19GB + 出力 4.7GB)。変換後は変換元を消せば約 5GB
- [uv](https://docs.astral.sh/uv/) (`brew install uv`)

## インストール

### 1. Claude Code 本体(このリポジトリには含まれません)
Claude Code は再配布できないため、公式の手順で各自インストールしてください。

```bash
# 公式インストーラ (macOS / Linux)
curl -fsSL https://claude.ai/install.sh | bash
# または npm (Node.js 18+)
npm install -g @anthropic-ai/claude-code

claude --version   # 確認
```
最新の手順は https://code.claude.com/docs を参照。ローカルモデルで使う分には Anthropic アカウントでのログインは不要です。

### 2. このリポジトリ
```bash
git clone https://github.com/shi3z/mightyCode.git
cd mightyCode
./setup.sh
```
ディスクが足りない場合は変換元の置き場を外付けなどに: `SRC_DIR=/Volumes/big/src ./setup.sh`
(`~/.local/bin` が PATH に入っていない場合は `export PATH="$HOME/.local/bin:$PATH"` を追加)

## 使い方
```bash
claude-local          # 起動(初回はモデル読み込みに数十秒)。引数は claude にそのまま渡る
claude-local -p "..." # 非対話実行
claude-local status   # バックエンドの状態
claude-local logs     # ログ
claude-local stop     # バックエンド停止(claude を閉じても常駐し続けるので、不要なら止める)
```

環境変数:
| 変数 | 既定 | 説明 |
|---|---|---|
| `MODEL_DIR` | `models/heretic-9b-mlx-4bit` | 使うMLXモデル |
| `MLX_PORT` / `PROXY_PORT` | 8080 / 8082 | ポート |
| `THINKING` | 0 | 1 で Qwen の思考モードを有効化(遅くなる) |
| `COMPACT_THRESHOLD` | 48000 | EoCC 圧縮を発動する推定トークン数(0 で無効) |
| `MAX_TOKENS_CAP` | 8192 | 1 回の最大出力 |

## EoCC (End-of-Conversation Compaction)
[arXiv:2611.05306 "You don't need long context"](https://arxiv.org/abs/2611.05306) の手法。コンテキストが閾値を超えると、
モデル自身に再開用の要約(目的・判明事実・変更内容・行き止まり・次の一手)を書かせ、
「元タスク + 要約 + それ以降のやり取り」だけを送るようにして履歴を短く保ちます(KV メモリとデコード遅延の削減)。
Claude Code 自体のシステムプロンプト+ツール定義で約 15〜20K トークンあるため、閾値は高め(48K)です。
論文の結果は API モデルでの測定で、ローカル 9B での効果は未検証です。

## 既知の注意点
- 画像入力は非対応(省略されます)
- 「Claude Code doesn't recognize the model "heretic-9b-local"」という警告が出ますが動作に影響はありません
- GPU で変換すると Metal の `GPU Timeout Error` になる環境があるため、変換は CPU で行います
- システムの mlx-lm 0.31.1 + mlx 0.32 では `mlx_lm.server` が落ちたので、専用 venv に最新の mlx-lm を入れます
- 9B モデルなので、複雑なエージェント作業の品質は Claude 本家に遠く及びません
- このモデルは検閲解除(uncensored)版です。利用は自己責任で
