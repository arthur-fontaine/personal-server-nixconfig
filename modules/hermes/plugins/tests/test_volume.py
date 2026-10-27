"""Tests for unii's memory core: the volume and its compactor.

Run with Hermes' own interpreter (the flake check `unii`), from modules/hermes/plugins:

    python3 -I tests/test_volume.py
"""

import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from unii.compactor import Compactor  # noqa: E402
from unii.volume import Volume, VolumeLocked, WrongPassphrase, unlock_key  # noqa: E402


def fake_complete(messages):
    """A compaction model that always answers a short line naming its input."""
    task = messages[-1]["content"]
    return "summary of " + task.split("<input>")[-1].strip()[:40].replace("\n", " ")


class Temp(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)


class VolumeTest(Temp):
    def test_append_render_zoom_and_reload(self):
        v = Volume(self.root, "main")
        v.append("user", "hello")
        v.append("hermes", "hi there")
        v.set_node(0, 0, "user: hello")
        v.set_node(0, 1, "hermes: hi there")
        self.assertEqual(v.render(), "0+1|user: hello\n1+1|hermes: hi there")
        self.assertIn("hi there", v.zoom(1, 1))
        self.assertIn("error", v.zoom(1, 2))
        again = Volume(self.root, "main")
        self.assertEqual(again.count, 2)
        self.assertEqual(again.view, [(0, 0), (0, 1)])
        self.assertEqual(again.node(0, 1), "hermes: hi there")

    def test_long_text_is_split_and_tool_output_clipped(self):
        v = Volume(self.root, "main")
        ids = v.append("user", "é" * 20_000)  # 40 KB
        self.assertEqual(len(ids), 3)
        self.assertTrue(all(m["size"] <= 16_000 for m in v.messages))
        v.append("echo", "x" * 100_000)
        self.assertLess(len(v.messages[-1]["text"]), 31_000)

    def test_encrypted_volume(self):
        directory = os.path.join(self.root, "vault")
        key = unlock_key(directory, "vault", "correct horse")
        v = Volume(self.root, "vault", encrypted=True, key=key)
        v.append("user", "the secret is swordfish-plaintext")
        with open(os.path.join(directory, "messages.jsonl")) as f:
            self.assertNotIn("swordfish", f.read())
        with self.assertRaises(VolumeLocked):
            Volume(self.root, "vault", encrypted=True)
        with self.assertRaises(WrongPassphrase):
            unlock_key(directory, "vault", "wrong")
        again = Volume(self.root, "vault", encrypted=True, key=unlock_key(directory, "vault", "correct horse"))
        self.assertEqual(again.messages[0]["text"], "the secret is swordfish-plaintext")


class MergeTest(Temp):
    def test_view_shrinks_and_stays_a_cover(self):
        v = Volume(self.root, "main")
        c = Compactor(v, fake_complete, line_bytes=60, workers=2)
        for n in range(200):
            c.appended(v.append("user", f"message number {n} " + "z" * 30))
        self.assertTrue(v.wait_built(v.count, 20))
        deadline = time.time() + 20
        while v.missing_nodes() and time.time() < deadline:
            time.sleep(0.05)
        before = v.view_bytes()
        v.merge(2000)
        self.assertLess(v.view_bytes(), before)
        self.assertLessEqual(v.view_bytes(), 2000)
        covered = 0
        for level, index in v.view:
            self.assertEqual(index << level, covered)
            covered += 1 << level
        self.assertEqual(covered, v.count)
        # Old lines are coarse, recent ones fine.
        self.assertGreater(v.view[0][0], v.view[-1][0])
        c.stop()

    def test_short_sources_need_no_model(self):
        v = Volume(self.root, "main")
        calls = []
        c = Compactor(v, lambda m: calls.append(m) or "x", line_bytes=512, workers=1)
        c.appended(v.append("user", "short"))
        c.appended(v.append("hermes", "also short"))
        self.assertTrue(v.wait_built(2, 5))
        deadline = time.time() + 5
        while not v.has_node(1, 0) and time.time() < deadline:
            time.sleep(0.05)
        self.assertEqual(v.node(1, 0), "user: short\nhermes: also short")
        self.assertEqual(calls, [])
        c.stop()

    def test_too_long_reply_is_retried(self):
        v = Volume(self.root, "main")
        replies = iter(["y" * 300, "short enough"])
        seen = []

        def complete(messages):
            seen.append(messages)
            return next(replies)

        c = Compactor(v, complete, line_bytes=100, workers=1)
        self.assertEqual(c.build(0, v.append("user", "w" * 500)[0]), "short enough")
        self.assertIn("Too long", seen[1][-1]["content"])
        c.stop()


if __name__ == "__main__":
    unittest.main()
