#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/offline-python.sh - <<'PY'
import socket
try:
    connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    connection.connect(('127.0.0.1', 9))
except PermissionError:
    print('PASS: OS sandbox denied a network socket/connect attempt.')
except OSError as error:
    raise SystemExit(f'Unexpected socket error ({error.errno}); network isolation is not verified.')
else:
    raise SystemExit('FAIL: network connection was permitted.')
PY
