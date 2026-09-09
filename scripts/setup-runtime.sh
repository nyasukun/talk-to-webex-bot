#!/bin/bash
# This explicit setup command may access package indexes. The app never runs it automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then echo "Apple Silicon Macが必要です。" >&2; exit 1; fi
command -v uv >/dev/null || { echo "uvを先にインストールしてください: brew install uv python@3.12" >&2; exit 1; }
relay_root="$PWD"
relay_data="$HOME/Library/Application Support/LocalVoiceRelay"
relay_runtime="$relay_data/runtime"
umask 077
mkdir -p "$relay_runtime"
cp worker/pyproject.toml worker/uv.lock "$relay_runtime/"
extra=()
if [[ "${1:-}" == --voice ]]; then extra=(--extra voice); elif [[ -n "${1:-}" ]]; then echo "Usage: scripts/setup-runtime.sh [--voice]" >&2; exit 2; fi
uv sync --project "$relay_runtime" --locked --python 3.12 "${extra[@]}"
echo "ローカル実行環境を準備しました: $relay_runtime/.venv/bin/python"
echo "次に scripts/download-models.sh asr を実行してください。"
