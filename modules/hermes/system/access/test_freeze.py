"""Tests for freeze.py's choice of what to freeze. The freezing itself (chown
and ACLs) needs root, so it is replaced by a recorder.

    python3 -I test_freeze.py
"""

import getpass
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import freeze  # noqa: E402

DAY = 24 * 60 * 60


class FreezeTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.home = os.path.join(self.root, "home")
        os.makedirs(os.path.join(self.home, ".hermes"))
        os.makedirs(os.path.join(self.home, "workspace", "project"))
        self.ledger = os.path.join(self.root, "ledger.json")
        self.frozen = []
        self._real_freeze = freeze.freeze
        freeze.freeze = lambda path, st, agent, admin_uid: self.frozen.append(path)
        user = getpass.getuser()
        self.config = {
            "agent_user": user,
            "admin_user": user,
            "freeze_after": DAY,
            "ledger": self.ledger,
            "roots": [{"path": self.home, "exclude": [os.path.join(self.home, ".hermes")]}],
        }

    def tearDown(self):
        freeze.freeze = self._real_freeze
        shutil.rmtree(self.root, ignore_errors=True)

    def touch(self, *parts):
        path = os.path.join(self.home, *parts)
        with open(path, "w") as f:
            f.write("x")
        return path

    def test_new_files_stay_writable_and_enter_the_ledger(self):
        path = self.touch("workspace", "new.txt")
        self.assertEqual(freeze.scan(self.config, time.time()), 0)
        st = os.lstat(path)
        with open(self.ledger) as f:
            self.assertIn(f"{st.st_dev}:{st.st_ino}", json.load(f))

    def test_a_day_later_they_freeze(self):
        path = self.touch("workspace", "project", "old.txt")
        freeze.scan(self.config, time.time())
        self.assertEqual(self.frozen, [])
        freeze.scan(self.config, time.time() + DAY + 1)
        self.assertIn(path, self.frozen)
        self.assertIn(os.path.join(self.home, "workspace", "project"), self.frozen)
        self.assertNotIn(self.home, self.frozen)

    def test_the_ledger_beats_a_reset_birth_time(self):
        path = self.touch("workspace", "sneaky.txt")
        st = os.lstat(path)
        with open(self.ledger, "w") as f:
            json.dump({f"{st.st_dev}:{st.st_ino}": time.time() - 2 * DAY}, f)
        freeze.scan(self.config, time.time())
        self.assertIn(path, self.frozen)

    def test_mutable_paths_never_freeze(self):
        state = self.touch(".hermes", "state.db")
        freeze.scan(self.config, time.time() + 2 * DAY)
        self.assertNotIn(state, self.frozen)
        self.assertNotIn(os.path.join(self.home, ".hermes"), self.frozen)


    def test_sockets_and_pipes_never_freeze(self):
        import socket

        fifo = os.path.join(self.home, "workspace", "pipe")
        os.mkfifo(fifo)
        # A short path: AF_UNIX allows ~104 bytes.
        sock_dir = tempfile.mkdtemp(dir="/tmp")
        sock_path = os.path.join(sock_dir, "s.sock")
        server = socket.socket(socket.AF_UNIX)
        server.bind(sock_path)
        try:
            config = {**self.config, "roots": [*self.config["roots"], {"path": sock_dir}]}
            freeze.scan(config, time.time() + 2 * DAY)
            self.assertNotIn(fifo, self.frozen)
            self.assertNotIn(sock_path, self.frozen)
            self.assertIn(os.path.join(self.home, "workspace"), self.frozen)
        finally:
            server.close()
            shutil.rmtree(sock_dir, ignore_errors=True)

    def test_the_space_report(self):
        report = os.path.join(self.root, "report.json")
        config = {**self.config, "report": report}
        big = self.touch("workspace", "project", "big.bin")
        with open(big, "wb") as f:
            f.write(b"x" * 5000)
        now = time.time()
        freeze.scan(config, now)
        with open(report) as f:
            data = json.load(f)
        self.assertEqual(oct(os.stat(report).st_mode & 0o777), "0o644")
        group = data["upcoming"]["groups"][0]
        self.assertEqual(group["path"], os.path.join(self.home, "workspace", "project"))
        self.assertEqual((group["bytes"], group["files"]), (5000, 1))
        self.assertAlmostEqual(group["freezes_at"], now + DAY, delta=5)
        self.assertGreater(data["disk"]["free"], 0)
        self.assertEqual(data["frozen"]["bytes"], 0)
        # A day on it froze: in the home it counts as a leftover, not upcoming.
        freeze.scan({**config, "roots": [{**self.config["roots"][0], "leftovers": True}]}, now + DAY + 1)
        with open(report) as f:
            data = json.load(f)
        self.assertEqual(data["upcoming"]["bytes"], 0)
        self.assertEqual(data["frozen"]["groups"][0]["path"], os.path.join(self.home, "workspace", "project"))
        self.assertEqual((data["frozen"]["bytes"], data["frozen"]["files"]), (5000, 1))

    def test_leftovers_are_the_administrators_entries_in_the_home(self):
        # Hermes is someone else here: the test user's files stand for frozen ones.
        report = os.path.join(self.root, "report.json")
        self.touch("workspace", "kept.txt")
        config = {**self.config, "agent_user": "nobody", "report": report,
                  "roots": [{**self.config["roots"][0], "leftovers": True}]}
        self.assertEqual(freeze.scan(config, time.time()), 0)
        with open(report) as f:
            frozen = json.load(f)["frozen"]
        self.assertEqual((frozen["bytes"], frozen["files"]), (1, 1))
        self.assertEqual(self.frozen, [])


if __name__ == "__main__":
    unittest.main()
