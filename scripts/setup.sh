#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then python3 scripts/setup-signing.py; fi
scripts/setup-runtime.sh "${@}"
scripts/download-models.sh asr
if [[ "${1:-}" == --voice ]]; then scripts/download-models.sh voice; fi
scripts/build.sh
echo '起動: open "dist/Talk to Webex bot.app"'
