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


if __name__ == "__main__":
    unittest.main()
