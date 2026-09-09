#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/offline-python.sh" scripts/smoke-local.py "$@"
