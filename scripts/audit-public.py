#!/usr/bin/env python3
"""Inspect publishable files without printing matched values; --staged checks exact index bytes."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import sys

PUBLIC_ASSETS = {
    "integrations/raycast/assets/icon.png": "f38cb4aa79e66472114b39f8ad0fadf4a1bc9f5409e12ab920f5d28c46287687",
    "Resources/AppIcon.png": "f38cb4aa79e66472114b39f8ad0fadf4a1bc9f5409e12ab920f5d28c46287687",
    "Resources/AppIcon.icns": "b722b01f71de788696d104dad381a616e0c3ef3f2227671abd236e0641ced143",
}
PATTERNS = [
    ("credential literal", re.compile(r"Bearer\s+[A-Za-z0-9_\-=]{30,}")),
    ("GitHub credential", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}")),
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("home path", re.compile("/" + "Users" + r"/[a-zA-Z0-9_.-]+/")),
]
PRIVATE_EXTENSIONS = {
    ".wav", ".m4a", ".mp3", ".aif", ".aiff", ".flac", ".png", ".jpg", ".jpeg", ".heic", ".webp",
    ".mp4", ".mov", ".m4s", ".npy", ".npz", ".pt", ".onnx", ".safetensors", ".bin",
    ".pem", ".p12", ".pfx", ".keychain", ".keychain-db", ".log",
}


def inspect_data(relative, data, forbidden=()):
    errors = []
    if any(term.casefold() in relative.casefold() for term in forbidden):
        errors.append("forbidden private term")
    if relative in PUBLIC_ASSETS:
        if hashlib.sha256(data).hexdigest() != PUBLIC_ASSETS[relative]:
            errors.append("public asset changed; review and update its approved digest")
        return errors
    path = Path(relative)
    if (path.suffix.lower() in PRIVATE_EXTENSIONS or path.name == "settings.json" or path.name.startswith(".env")
            or any(part in {"artifacts", "private", "models", "dist"} or part.endswith(".screenstudio") for part in path.parts)):
        errors.append("private artifact type")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return errors + ["unexpected binary"]
    if any(term.casefold() in text.casefold() for term in forbidden):
        errors.append("forbidden private term")
    errors += [label for label, pattern in PATTERNS if pattern.search(text)]
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forbid", action="append", default=[], help="Additional private term; case-insensitive")
    parser.add_argument("--staged", action="store_true", help="Inspect index contents instead of working files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    options = ["--cached"] if args.staged else ["--cached", "--others", "--exclude-standard"]
    files = subprocess.check_output(["git", "ls-files", *options, "-z"], cwd=root).split(b"\0")
    errors = []
    for raw in set(files) - {b""}:
        relative = raw.decode("utf-8")
        path = root / relative
        if path.is_symlink():
            errors.append((relative, "symbolic link"))
            continue
        if args.staged:
            data = subprocess.check_output(["git", "show", ":" + relative], cwd=root)
        elif path.is_file():
            data = path.read_bytes()
        else:
            continue
        errors.extend((relative, kind) for kind in inspect_data(relative, data, args.forbid))
    if errors:
        for path, kind in sorted(set(errors)):
            print(f"FAIL {path}: {kind}")
        return 1
    print(f"PASS: {len(set(files) - {b''})} publishable files inspected; no configured private terms or sensitive artifacts found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
