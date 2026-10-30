"""Tests for scripts/var-dump-receiver.py, run by scripts/check.sh. Each test serves the real handler
on an ephemeral port, writing to a temp dir."""

import http.client
import importlib.util
import json
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from http.server import HTTPServer
from io import StringIO
from pathlib import Path

SCRIPT = Path(__file__).with_name("var-dump-receiver.py")
spec = importlib.util.spec_from_file_location("var_dump_receiver", SCRIPT)
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


class Receiver(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name)
        receiver.out_dir = self.out
        receiver.current_snapshot = None
        self.server = HTTPServer(("127.0.0.1", 0), receiver.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def post(self, path, body, headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1])
        with redirect_stdout(StringIO()):
            conn.request("POST", path, data, headers or {})
            status = conn.getresponse().status
        conn.close()
        return status

    def part(self, n, total, names):
        return self.post("/snapshot", {"part": n, "totalParts": total, "totalVars": 9,
                                       "vars": [{"name": x} for x in names]})

    def test_snapshot_is_partial_until_last_part(self):
        self.assertEqual(self.part(1, 2, ["a"]), 200)
        self.assertEqual([p.suffix for p in self.out.glob("snapshot-*")], [".partial"])
        self.assertEqual(self.part(2, 2, ["b"]), 200)
        done = list(self.out.glob("snapshot-*"))
        self.assertEqual([p.suffix for p in done], [".jsonl"])
        self.assertEqual(len(done[0].read_text().splitlines()), 2)

    def test_abandoned_snapshot_stays_partial(self):
        self.part(1, 3, ["a"])
        self.part(2, 3, ["b"])
        self.assertEqual([p.suffix for p in self.out.glob("snapshot-*")], [".partial"])

    def test_part_without_start_is_refused(self):
        self.assertEqual(self.part(2, 2, ["b"]), 409)

    def test_invalid_utf8_is_decoded_with_replacement(self):
        body = b'{"changes": [{"name": "A\xff", "old": 1, "new": 2}]}'
        self.assertEqual(self.post("/changes", body), 200)
        row = json.loads((self.out / "changes.jsonl").read_text())
        self.assertEqual(row["name"], "A�")

    def test_browser_requests_are_refused(self):
        body = {"changes": []}
        for headers in (
            {"Origin": "https://evil.example"},
            {"Origin": "http://localhost:3000"},
            {"Host": "evil.example:8765"},
            {"Host": "evil.com@127.0.0.1"},
            {"Host": "[::1]:8765"},
            {"Host": "localhost.:8765"},
        ):
            self.assertEqual(self.post("/changes", body, headers), 403, headers)
        for host in ("127.0.0.1:8765", "localhost:8765", "127.0.0.1"):
            self.assertEqual(self.post("/changes", body, {"Host": host}), 200, host)
        self.assertEqual(self.post("/changes", body), 200)  # no Origin, Host 127.0.0.1:port

    def test_malformed_bodies_are_400s(self):
        for path, body in (
            ("/changes", [1]),
            ("/changes", {}),
            ("/changes", {"changes": {}}),
            ("/snapshot", {}),
            ("/snapshot", {"part": "1", "totalParts": 1, "vars": []}),
            ("/snapshot", {"part": 2, "totalParts": 1, "vars": []}),  # would never finish
            ("/snapshot", {"part": 0, "totalParts": 1, "vars": []}),
            ("/snapshot", {"part": 1, "totalParts": 0, "vars": []}),
        ):
            self.assertEqual(self.post(path, body), 400, (path, body))

    def test_changes_batch_with_a_bad_element_writes_nothing(self):
        self.assertEqual(self.post("/changes", {"changes": [{"name": "A"}, 5]}), 400)
        self.assertFalse((self.out / "changes.jsonl").exists())

    def test_non_numeric_content_length_is_a_400(self):
        self.assertEqual(self.post("/changes", b"{}", {"Content-Length": "abc"}), 400)

    def test_empty_body_is_a_400(self):
        self.assertEqual(self.post("/changes", b""), 400)


if __name__ == "__main__":
    unittest.main()
