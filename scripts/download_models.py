#!/usr/bin/env python3
"""Explicit online acquisition, separate from the network-denied inference worker."""
import argparse
import json
import os
from pathlib import Path

MODELS = {
    "asr": ("mlx-community/whisper-large-v3-turbo", "whisper"),
    "asr-large": ("mlx-community/whisper-large-v3-mlx", "whisper-large"),
    "voice": ("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit", "voice"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=MODELS)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    # Use macOS system CA roots, preserving certificate verification.
    import ssl
    import httpx
    from huggingface_hub import snapshot_download, set_client_factory
    context = ssl.create_default_context()
    set_client_factory(lambda: httpx.Client(verify=context, follow_redirects=True, timeout=120))
    os.umask(0o077)
    repo, folder = MODELS[args.model]
    lock_path = Path(__file__).with_name("models.lock.json")
    lock = json.loads(lock_path.read_text())
    revision = lock[args.model]["revision"]
    target = args.destination.expanduser().resolve() / folder
    print(f"Downloading {repo} @ {revision} to {target}")
    snapshot_download(repo_id=repo, revision=revision, local_dir=str(target),
                      allow_patterns=["*.json", "*.safetensors", "*.npz", "*.txt", "*.tiktoken", "*.model", "*.md", "LICENSE*"],
                      token=False)
    (target / "acquisition.json").write_text(json.dumps({"repository": repo, "revision": revision}, indent=2) + "\n")
    print("取得が完了しました。通常実行ではこのローカルフォルダだけを使用します。")


if __name__ == "__main__":
    main()
