#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
developer_dir=$(xcode-select -p)
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ -d "$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks" ]]; then
  frameworks="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
swift test --disable-sandbox --disable-xctest --enable-swift-testing \
  -Xswiftc -F -Xswiftc "$frameworks" \
  -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
relay_python="$HOME/Library/Application Support/LocalVoiceRelay/runtime/.venv/bin/python"
if [[ -n "${RELAY_TEST_PYTHON:-}" ]]; then relay_python="$RELAY_TEST_PYTHON"; fi
if [[ ! -x "$relay_python" ]]; then relay_python=python3; fi
"$relay_python" -m unittest discover -s worker/tests -v
"$relay_python" -m unittest discover -s Tests/ScriptTests -v
