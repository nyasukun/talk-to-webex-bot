#!/usr/bin/env python3
"""Print an offline issue draft without reading settings, credentials, logs or recordings."""
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git_value(*args):
    try:
        result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=5)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def version(value):
    return value if isinstance(value, str) and re.fullmatch(r"[0-9.]{1,32}", value) else "不明"


def collect():
    try:
        with (ROOT / "Resources/Info.plist").open("rb") as file:
            info = plistlib.load(file)
    except (OSError, ValueError, plistlib.InvalidFileException):
        info = {}
    commit = git_value("rev-parse", "--verify", "HEAD")
    if not re.fullmatch(r"[a-f0-9]{40,64}", commit):
        commit = "コミットなし／取得不可"
    machine = platform.machine()
    if machine not in {"arm64", "x86_64"}:
        machine = "その他"
    return "\n".join([
        "## 起きたこと", "（個人情報を含めず、症状を記入）", "",
        "## 再現手順", "1. ", "2. ", "3. ", "",
        "## 期待した動作", "（記入）", "", "## 実際の動作・頻度", "（記入）", "",
        "## 環境（オフラインで取得）",
        f"- macOS: {version(platform.mac_ver()[0])}", f"- CPU: {machine}",
        f"- ソースのバージョン: {version(info.get('CFBundleShortVersionString'))}",
        f"- ソースのビルド: {version(info.get('CFBundleVersion'))}",
        f"- コミット: {commit}",
        f"- 作業コピーの変更: {'あり' if git_value('status', '--porcelain') else 'なし／取得不可'}",
        f"- uv: {'あり' if shutil.which('uv') else '未検出'}",
        f"- Swift: {'あり' if shutil.which('swift') else '未検出'}", "",
        "## 試した対処", "（実施したものだけ記入）", "",
        "## 診断ログ（任意）", "（アプリのログから該当部分を確認して貼り付け）", "",
        "<!-- ソースの版と起動中アプリの版が異なる場合は追記してください。 -->",
        "<!-- トークン、宛先、合言葉、会話、OCR、画像、録音、ユーザ名入りのパスを含めないでください。 -->",
    ])


if __name__ == "__main__":
    print(collect())
