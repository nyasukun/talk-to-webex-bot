#!/usr/bin/env python3
"""Sign local builds with a persistent certificate, without a network timestamp."""
import json
import os
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
identity = os.environ.get("SIGNING_IDENTITY")
command = ["/usr/bin/codesign", "--force", "--timestamp=none", "--identifier", "org.localvoicerelay.app"]
if not identity:
    profile = Path.home() / "Library/Application Support/LocalVoiceRelay/signing/profile.json"
    if not profile.is_file():
        sys.exit("署名の初回設定が必要です: python3 scripts/setup-signing.py")
    settings = json.loads(profile.read_text())
    identity = settings["identity"]
    command += ["--keychain", settings["keychain"]]
if identity == "-":
    print("注意: アドホック署名では再ビルド後に権限の再登録が必要です。", file=sys.stderr)
command += ["--sign", identity, str(app)]
try:
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
except subprocess.TimeoutExpired:
    sys.exit("署名の確認待ちが3分を超えました。macOSのキーチェーン確認を許可してから再実行してください。")
if result.returncode:
    # Never fall back to an identity that would invalidate saved privacy grants.
    sys.exit("署名に失敗しました。キーチェーンの許可・ロック状態を確認してください。別の署名へ自動切替しません。")
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
print("Signature verified.")
