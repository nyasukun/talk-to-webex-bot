#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox
binary_dir=$(swift build --show-bin-path --disable-sandbox)
sources=()
for source in Sources/LocalVoiceRelay/*.swift Sources/LocalVoiceRelay/Views/*.swift; do
    if [[ "$source" != */LocalVoiceRelayApp.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -I "$binary_dir/Modules" "${sources[@]}" "$binary_dir"/RelayCore.build/*.o scripts/render-ui.swift -o .build/render-ui
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' .build/render-ui
