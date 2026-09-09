#!/usr/bin/env python3
"""Create one local code-signing identity; keep its private key in the user keychain."""
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

NAME = "Local Voice Relay Development"
DIRECTORY = Path.home() / "Library/Application Support/LocalVoiceRelay/signing"
PROFILE = DIRECTORY / "profile.json"


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} {args[1]} failed: {result.stderr.strip()[:400]}")
    return result.stdout


def main():
    os.umask(0o077)
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    if PROFILE.exists():
        profile = json.loads(PROFILE.read_text())
        identities = run(["/usr/bin/security", "find-identity", "-p", "codesigning", profile["keychain"]])
        if profile["identity"] not in identities:
            raise RuntimeError("保存済み署名鍵がありません。証明書を自動で作り直さず停止しました。キーチェーンを復元してください。")
        print("既存のローカル署名証明書を再利用します。")
        return
    keychain = run(["/usr/bin/security", "default-keychain", "-d", "user"]).strip().strip('"')
    found = subprocess.run(["/usr/bin/security", "find-certificate", "-a", "-c", NAME, "-Z", keychain], capture_output=True, text=True)
    hashes = re.findall(r"SHA-1 hash: ([A-Fa-f0-9]{40})", found.stdout)
    if not hashes:
        with tempfile.TemporaryDirectory(prefix="certificate-", dir=DIRECTORY) as temporary:
            folder = Path(temporary)
            config = folder / "certificate.cnf"
            config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Local Voice Relay Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
            key, certificate, bundle = [folder / name for name in ("key.pem", "certificate.pem", "identity.p12")]
            run(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                 "-config", str(config), "-keyout", str(key), "-out", str(certificate)])
            passphrase = secrets.token_urlsafe(32)
            password_file = folder / "import-password"
            password_file.write_text(passphrase)
            # A one-use import password protects the temporary bundle; it is never logged or retained.
            run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
                 "-name", NAME, "-out", str(bundle), "-passout", "file:" + str(password_file),
                 "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
            run(["/usr/bin/security", "import", str(bundle), "-k", keychain, "-f", "pkcs12", "-P", passphrase, "-x", "-T", "/usr/bin/codesign"])
        found = run(["/usr/bin/security", "find-certificate", "-a", "-c", NAME, "-Z", keychain])
        hashes = re.findall(r"SHA-1 hash: ([A-Fa-f0-9]{40})", found)
    if len(hashes) != 1:
        raise RuntimeError("同名の署名証明書が複数あります。キーチェーンで確認してから再実行してください。")
    identities = run(["/usr/bin/security", "find-identity", "-p", "codesigning", keychain])
    if hashes[0] not in identities:
        raise RuntimeError("証明書に対応する署名用秘密鍵が見つかりません。")
    temporary_profile = DIRECTORY / "profile.pending"
    temporary_profile.write_text(json.dumps({"identity": hashes[0], "keychain": keychain}) + "\n")
    temporary_profile.replace(PROFILE)
    print("ローカル署名証明書を保存しました。以後のビルドで同じ鍵を使います。システムの信頼設定は変更していません。")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
