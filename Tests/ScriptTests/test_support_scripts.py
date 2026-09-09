import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SupportScriptTests(unittest.TestCase):
    def test_report_rejects_free_text_version_and_git_output(self):
        report = load("collect-issue-report")
        with patch.object(report, "git_value", return_value="synthetic-private"), patch.object(report.platform, "machine", return_value="synthetic-private"), patch.object(report.platform, "mac_ver", return_value=("synthetic-private", (), "")):
            result = report.collect()
        self.assertNotIn("synthetic-private", result)

    def test_public_icons_are_approved_by_exact_content(self):
        audit = load("audit-public")
        for asset in audit.PUBLIC_ASSETS:
            self.assertEqual(audit.inspect_data(asset, (ROOT / asset).read_bytes()), [])
            self.assertTrue(audit.inspect_data(asset, b"replaced-private-image"))

    def test_unapproved_media_and_credentials_are_rejected(self):
        audit = load("audit-public")
        for name in ["artifacts/note.txt", "movie.mp4", "private/image.icns", "voice.wav", ".env.local"]:
            self.assertTrue(audit.inspect_data(name, b"content"))
        self.assertTrue(audit.inspect_data("source.swift", ("Bearer " + "a" * 32).encode()))
        self.assertTrue(audit.inspect_data("source.swift", ("ghp_" + "a" * 36).encode()))
        self.assertTrue(audit.inspect_data("source.swift", b"private-word", ["PRIVATE-WORD"]))
        self.assertEqual(audit.inspect_data("source.swift", b"import Foundation"), [])


if __name__ == "__main__":
    unittest.main()
