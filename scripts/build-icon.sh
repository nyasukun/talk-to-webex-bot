#!/bin/bash
# Rebuild every macOS icon size from the generated source without extra dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
icon_root=$(mktemp -d "$PWD/.build/icon.XXXXXX")
trap 'rm -rf "$icon_root"' EXIT
icon_set="$icon_root/AppIcon.iconset"
mkdir -p "$icon_set"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$icon_set/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "$icon_set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set" -o Resources/AppIcon.icns
echo 'Built Resources/AppIcon.icns'
