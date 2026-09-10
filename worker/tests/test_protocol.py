import io
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay_worker as worker


class ProtocolTests(unittest.TestCase):
    def serve(self, data, instance=None):
        output = io.StringIO()
        worker.serve(io.BytesIO(data), output, instance or worker.Worker())
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_dependency_value_errors_never_return_private_contents(self):
        def fail(request):
            raise ValueError("synthetic-private-path-and-transcript")
        result = self.serve(b'{"action":"ping"}\n', SimpleNamespace(handle=fail))
        self.assertIn("error", result[0])
        self.assertNotIn("synthetic-private", str(result))

    def test_app_authored_actionable_errors_are_preserved(self):
        result = self.serve(b'{"action":"unsupported"}\n')
        self.assertEqual(result[0]["error"], "未対応の音声処理です。")

    def test_malformed_and_non_object_json_do_not_poison_next_request(self):
        results = self.serve(b'{bad}\n[]\nnull\n{"action":"ping"}\n')
        self.assertTrue(all("error" in result for result in results[:3]))
        self.assertTrue(results[3]["ready"])

    def test_oversized_frame_closes_session_without_processing_trailing_request(self):
        results = self.serve(b"x" * (worker.MAX_REQUEST_BYTES + 2) + b'\n{"action":"ping"}\n')
        self.assertEqual(len(results), 1)
        self.assertIn("error", results[0])

    def test_truncated_valid_json_is_not_executed(self):
        results = self.serve(b'{"action":"ping"}')
        self.assertIn("error", results[0])

    def test_nonfinite_model_output_is_reported_as_error(self):
        results = self.serve(b'{"action":"ping"}\n', SimpleNamespace(handle=lambda request: {"value": float("nan")}))
        self.assertIn("error", results[0])


if __name__ == "__main__":
    unittest.main()
