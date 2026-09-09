#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
relay_python="$HOME/Library/Application Support/LocalVoiceRelay/runtime/.venv/bin/python"
exec /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' "$relay_python" "$@"
