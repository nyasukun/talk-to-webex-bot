#!/bin/bash
# User-invoked acquisition phase. Inference remains offline.
set -euo pipefail
cd "$(dirname "$0")/.."
relay_data="$HOME/Library/Application Support/LocalVoiceRelay"
relay_python="$relay_data/runtime/.venv/bin/python"
[[ -x "$relay_python" ]] || { echo "scripts/setup-runtime.sh を先に実行してください。" >&2; exit 1; }
exec "$relay_python" scripts/download_models.py "${1:-asr}" --destination "$relay_data/models"
