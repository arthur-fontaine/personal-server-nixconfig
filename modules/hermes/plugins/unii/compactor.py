"""Builds a volume's tree in the background: UniiChat's section 4,
https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449

A message's node is built once fewer than 8 lines before it are unbuilt; a merge
once both its halves are built. Nodes that are ready wait in a queue, never
found by scanning the tree. A source that fits in one line is its own node,
with no model call.
"""

from __future__ import annotations

import logging
import queue
import threading
from typing import Callable

from .prompts import COMPACTION_SYSTEM, compress_task, merge_task, too_long
from .volume import Volume, cut_utf8, node_name, utf8_size

logger = logging.getLogger(__name__)

# (messages) -> reply text. Raises on failure.
Complete = Callable[[list[dict]], str]

WORKERS = 8
TRIES = 5
# The chat before a node, for its summary to make sense: re-sent with every
# summary and merge, so the bulk of their cost.
CONTEXT_BYTES = 8_000


class Compactor:
    def __init__(self, volume: Volume, complete: Complete, line_bytes: int = 512, workers: int = WORKERS):
        self.volume = volume
        self.complete = complete
        self.line_bytes = line_bytes
        self._queue: queue.Queue[tuple[int, int] | None] = queue.Queue()
        self._queued: set[tuple[int, int]] = set()
        self._lock = threading.Lock()
        self._threads = [
            threading.Thread(target=self._work, name=f"unii-{volume.name}-{k}", daemon=True) for k in range(workers)
        ]
        for thread in self._threads:
            thread.start()
        for level, index in volume.missing_nodes():
            if level == 0 or self._halves_built(level, index):
                self._enqueue(level, index)

    def stop(self) -> None:
        for _ in self._threads:
            self._queue.put(None)

    # ── queueing ─────────────────────────────────────────────────────────

    def _halves_built(self, level: int, index: int) -> bool:
        return self.volume.has_node(level - 1, 2 * index) and self.volume.has_node(level - 1, 2 * index + 1)

    def _enqueue(self, level: int, index: int) -> None:
        with self._lock:
            if (level, index) in self._queued or self.volume.has_node(level, index):
                return
            self._queued.add((level, index))
        self._queue.put((level, index))

    def appended(self, ids: list[int]) -> None:
        for i in ids:
            self._enqueue(0, i)

    def _built(self, level: int, index: int) -> None:
        sibling = index ^ 1
        parent = (level + 1, index // 2)
        if self.volume.has_node(level, sibling) and self.volume.node_exists(*parent):
            self._enqueue(*parent)

    def _work(self) -> None:
        while True:
            item = self._queue.get()
            if item is None:
                return
            level, index = item
            try:
                self.volume.set_node(level, index, self.build(level, index))
                self._built(level, index)
            except Exception:
                # Tried again at the next message.
                logger.warning("unii: could not build %s in %s", node_name(level, index), self.volume.name, exc_info=True)
            finally:
                with self._lock:
                    self._queued.discard((level, index))

    def retry_failed(self) -> None:
        for level, index in self.volume.missing_nodes():
            if level == 0 or self._halves_built(level, index):
                self._enqueue(level, index)

    # ── building ─────────────────────────────────────────────────────────

    def _context(self, upto: int) -> str:
        """The view before the node, its newest lines up to CONTEXT_BYTES."""
        lines = self.volume.render(upto=upto).split("\n")
        kept, size = [], 0
        for line in reversed(lines):
            size += utf8_size(line) + 1
            if size > CONTEXT_BYTES:
                break
            kept.append(line)
        return "\n".join(reversed(kept))

    def build(self, level: int, index: int) -> str:
        limit = self.line_bytes
        if level == 0:
            m = self.volume.message(index)
            source = f"{m['kind']}: {m['text']}"
            if utf8_size(source) <= limit:
                return source
            task = compress_task(index, m["kind"], m["text"], limit)
            first = index
        else:
            a = self.volume.node(level - 1, 2 * index)
            b = self.volume.node(level - 1, 2 * index + 1)
            joined = f"{a}\n{b}"
            if utf8_size(joined) <= limit:
                return joined
            n = 1 << level
            first = index * n
            task = merge_task(
                node_name(level - 1, 2 * index), node_name(level - 1, 2 * index + 1), a, b, first, first + n - 1, limit
            )
        return self._ask(task, upto=first, limit=limit)

    def _ask(self, task: str, upto: int, limit: int) -> str:
        messages = [
            {"role": "system", "content": COMPACTION_SYSTEM},
            {"role": "user", "content": f"<chat>\n{self._context(upto)}\n</chat>\n\n{task}"},
        ]
        best = None
        for _ in range(TRIES):
            reply = self.complete(messages).strip()
            if best is None or utf8_size(reply) < utf8_size(best):
                best = reply
            size = utf8_size(reply)
            # A few bytes over is fine: the view measures real sizes.
            if size <= limit + 16:
                return reply
            messages += [
                {"role": "assistant", "content": reply},
                {"role": "user", "content": too_long(size, limit, cut_utf8(reply, limit))},
            ]
        return cut_utf8(best, limit)
