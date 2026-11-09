"""Tests for space.py: hermes-space's view and the owner's weekly line,
against a fake Bot API on loopback.

    python3 -I test_space.py
"""

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import space  # noqa: E402

GB = 1024 ** 3
HOME = "/Users/hermes"
NOW = 1_800_000_000


def report(frozen_bytes=0):
    return {
        "updated_at": NOW - 60, "freeze_after": 86400, "disk": {"free": 142 * GB, "total": 926 * GB},
        "upcoming": {"bytes": 4 * GB, "files": 1203, "groups": [
            {"path": f"{HOME}/workspace/build-cache", "bytes": 4 * GB, "files": 1203, "freezes_at": NOW + 3 * 3600 + 600}]},
        "frozen": {"bytes": frozen_bytes, "files": 5302 if frozen_bytes else 0, "groups": [
            {"path": f"{HOME}/workspace/old-clone", "bytes": frozen_bytes, "files": 5302}] if frozen_bytes else []},
    }


class Telegram(BaseHTTPRequestHandler):
    sent = []

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        Telegram.sent.append({"path": self.path, **{k: v[0] for k, v in parse_qs(body).items()}})
        self.send_response(200)
        self.send_header("Content-Length", "11")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *args):
        pass


class SpaceTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.report = os.path.join(self.dir, "report.json")
        self.secrets = os.path.join(self.dir, "secrets.env")
        with open(self.secrets, "w") as f:
            f.write("TELEGRAM_BOT_TOKEN=123:abc\nTELEGRAM_ALLOWED_USERS=111,222\n")
        self.httpd = HTTPServer(("127.0.0.1", 0), Telegram)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        Telegram.sent = []

    def tearDown(self):
        self.httpd.shutdown()
        shutil.rmtree(self.dir, ignore_errors=True)

    def config(self, threshold=20 * GB):
        return {"report": self.report, "home": HOME, "threshold": threshold, "secrets_file": self.secrets,
                "telegram_api": f"http://127.0.0.1:{self.httpd.server_address[1]}"}

    def write(self, data):
        with open(self.report, "w") as f:
            json.dump(data, f)

    def test_the_view(self):
        text = space.show(report(34 * GB), {"total": 16 * GB, "available": 9 * GB}, NOW, HOME)
        self.assertIn("Disk: 142.0 GB free of 926.0 GB.", text)
        self.assertIn("Memory: 9.0 GB available of 16.0 GB.", text)
        self.assertIn("4.0 GB  ~/workspace/build-cache  (1203 files, the first freezes in 3 h 10 min)", text)
        self.assertIn("34.0 GB  ~/workspace/old-clone  (5302 files)", text)
        self.assertNotIn("old:", text)
        self.assertIn("No space report yet", space.show(None, None, NOW))

    def test_no_line_under_the_threshold(self):
        self.write(report(3 * GB))
        self.assertFalse(space.weekly(self.config()))
        self.assertEqual(Telegram.sent, [])

    def test_a_line_past_it(self):
        self.write(report(34 * GB))
        self.assertTrue(space.weekly(self.config()))
        [sent] = Telegram.sent
        self.assertEqual((sent["path"], sent["chat_id"]), ("/bot123:abc/sendMessage", "111"))
        self.assertTrue(sent["text"].startswith("Hermes' frozen leftovers take 34.0 GB (5302 files), mostly "
                                                "~/workspace/old-clone (34.0 GB)."), sent["text"])
        self.assertIn("nothing deletes them", sent["text"])

    def test_no_report_no_line(self):
        self.assertFalse(space.weekly(self.config()))


if __name__ == "__main__":
    unittest.main()
