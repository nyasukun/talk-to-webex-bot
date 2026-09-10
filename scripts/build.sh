#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
prepare_only=false
if [[ $# -gt 0 ]]; then
    if [[ $# == 1 && "$1" == --prepare ]]; then
        prepare_only=true
    else
        echo 'Usage: scripts/build.sh [--prepare]' >&2
        exit 2
    fi
fi
require_stopped() {
    if pgrep -x LocalVoiceRelay >/dev/null; then
        echo 'ビルド前にTalk to Webex botを終了してください。実行中のアプリは上書きしません。' >&2
        exit 1
    else
        local result=$?
        if [[ "$result" != 1 ]]; then
            echo 'アプリの終了状態を確認できないため、入れ替えを中止しました。' >&2
            exit 1
        fi
    fi
}
require_stopped
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration" --disable-sandbox
binary_dir=$(swift build -c "$configuration" --show-bin-path --disable-sandbox)
destination="$PWD/dist/Talk to Webex bot.app"
package_root=$(mktemp -d "$PWD/.build/package.XXXXXX")
cleanup() {
    if [[ ! -d "$destination" && -d "$package_root/previous.app" ]]; then
        mv "$package_root/previous.app" "$destination"
    fi
    rm -rf "$package_root"
}
trap cleanup EXIT
app="$package_root/Talk to Webex bot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/worker"
cp "$binary_dir/LocalVoiceRelay" "$app/Contents/MacOS/LocalVoiceRelay"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/ja.lproj "$app/Contents/Resources/"
cp worker/relay_*.py "$app/Contents/Resources/worker/"
if [[ "$prepare_only" == false ]]; then python3 scripts/sign-app.py "$app"; fi
require_stopped
mkdir -p "$PWD/dist"
if [[ -d "$destination" ]]; then mv "$destination" "$package_root/previous.app"; fi
mv "$app" "$destination"
if [[ "$prepare_only" == true ]]; then
    echo "署名待ち: $destination"
    echo '起動前に実行: python3 scripts/sign-app.py "dist/Talk to Webex bot.app"'
else
    echo "Built: $destination"
fi
