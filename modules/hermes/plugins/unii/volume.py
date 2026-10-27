"""A memory volume: one append-only chat log, its tree of summaries and its view.

This is the storage of UniiChat's design, sections 1 to 3:
https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449

Every chat writes into one volume: the main chat into `main`, a sub-chat into
a shared named volume or into one of its own.

    messages.jsonl   {i, kind, text, size, date}, one per line, append-only
    tree.jsonl       {l, i, text, size}, one node per line, append-only
    view.json        the view, as [l, i] pairs, oldest first
    meta.json        an encrypted volume's salt and key check

node(0, i) is message i in at most `line_bytes`; node(l, i) merges node(l-1, 2i)
and node(l-1, 2i+1) and covers the 2^l messages from i*2^l on, named
"<first message>+<count>".

An encrypted volume stores every line as base64(nonce + AES-256-GCM
ciphertext), with the key derived from a passphrase by scrypt. Without the key
it cannot be opened at all.
"""

from __future__ import annotations

import base64
import contextlib
import fcntl
import json
import os
import shutil
import threading
import time
from datetime import datetime, timezone

# A tool's output is clipped to its head and tail; other long texts are split
# over several messages in a row, never cut.
TOOL_OUTPUT_LIMIT = 30_000
MESSAGE_CHUNK = 16_000

KINDS = ("user", "hermes", "tool", "echo", "work", "note")


class VolumeLocked(Exception):
    """The volume is encrypted and no key was given."""


class WrongPassphrase(Exception):
    pass


def utf8_size(text: str) -> int:
    return len(text.encode("utf-8"))


def cut_utf8(text: str, limit: int) -> str:
    """The longest prefix of text that fits in limit bytes."""
    data = text.encode("utf-8")[:limit]
    return data.decode("utf-8", errors="ignore")


def clip_tool_output(text: str, limit: int = TOOL_OUTPUT_LIMIT) -> str:
    if len(text) <= limit:
        return text
    half = limit // 2
    return f"{text[:half]}\n[… {len(text) - limit} characters clipped …]\n{text[-half:]}"


def split_message(text: str, chunk: int = MESSAGE_CHUNK) -> list[str]:
    """Split text into pieces of at most `chunk` bytes, on character boundaries."""
    pieces = []
    while utf8_size(text) > chunk:
        head = cut_utf8(text, chunk)
        pieces.append(head)
        text = text[len(head):]
    pieces.append(text)
    return pieces


def node_name(level: int, index: int) -> str:
    n = 1 << level
    return f"{index * n}+{n}"


class Cipher:
    """AES-256-GCM over single lines, the volume name as associated data."""

    SCRYPT = {"n": 2**15, "r": 8, "p": 1}
    CHECK = b"hermes-unii-volume"

    def __init__(self, key: bytes, aad: bytes):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        self._aead = AESGCM(key)
        self._aad = aad

    @classmethod
    def derive(cls, passphrase: str, salt: bytes) -> bytes:
        from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

        params = cls.SCRYPT
        return Scrypt(salt=salt, length=32, n=params["n"], r=params["r"], p=params["p"]).derive(
            passphrase.encode("utf-8")
        )

    def seal(self, data: bytes) -> str:
        nonce = os.urandom(12)
        return base64.b64encode(nonce + self._aead.encrypt(nonce, data, self._aad)).decode("ascii")

    def open(self, line: str) -> bytes:
        raw = base64.b64decode(line)
        return self._aead.decrypt(raw[:12], raw[12:], self._aad)


def unlock_key(directory: str, name: str, passphrase: str) -> bytes:
    """The key of an encrypted volume, creating its meta.json on first use."""
    os.makedirs(directory, mode=0o700, exist_ok=True)
    meta_path = os.path.join(directory, "meta.json")
    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except FileNotFoundError:
        salt = os.urandom(16)
        key = Cipher.derive(passphrase, salt)
        meta = {
            "kdf": "scrypt",
            **Cipher.SCRYPT,
            "salt": base64.b64encode(salt).decode("ascii"),
            "check": Cipher(key, name.encode()).seal(Cipher.CHECK),
        }
        tmp = meta_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(meta, f)
        os.replace(tmp, meta_path)
        return key
    key = Cipher.derive(passphrase, base64.b64decode(meta["salt"]))
    try:
        if Cipher(key, name.encode()).open(meta["check"]) != Cipher.CHECK:
            raise WrongPassphrase(name)
    except Exception as err:
        raise WrongPassphrase(name) from err
    return key


class Volume:
    """One volume, safe to share between threads; writes also hold a file lock."""

    def __init__(self, root: str, name: str, *, encrypted: bool = False, key: bytes | None = None):
        self.name = name
        self.dir = os.path.join(root, name)
        self.encrypted = encrypted
        if encrypted and key is None:
            raise VolumeLocked(name)
        self._cipher = Cipher(key, name.encode()) if encrypted else None
        self._lock = threading.RLock()
        self._built = threading.Condition(self._lock)
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        self.messages: list[dict] = []
        self.nodes: dict[tuple[int, int], str] = {}
        self.view: list[tuple[int, int]] = []
        self._load()

    # ── files ────────────────────────────────────────────────────────────

    def _path(self, name: str) -> str:
        return os.path.join(self.dir, name)

    @contextlib.contextmanager
    def _file_lock(self):
        with open(self._path(".lock"), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def _encode(self, record: dict) -> str:
        data = json.dumps(record, ensure_ascii=False)
        return self._cipher.seal(data.encode("utf-8")) if self._cipher else data

    def _decode(self, line: str) -> dict:
        if self._cipher:
            return json.loads(self._cipher.open(line))
        return json.loads(line)

    def _read_lines(self, name: str) -> list[dict]:
        try:
            with open(self._path(name)) as f:
                return [self._decode(line) for line in f if line.strip()]
        except FileNotFoundError:
            return []

    def _append_lines(self, name: str, records: list[dict]) -> None:
        with open(self._path(name), "a") as f:
            for record in records:
                f.write(self._encode(record) + "\n")
            f.flush()
            os.fsync(f.fileno())

    def _load(self) -> None:
        self.messages = self._read_lines("messages.jsonl")
        for node in self._read_lines("tree.jsonl"):
            self.nodes[(node["l"], node["i"])] = node["text"]
        try:
            with open(self._path("view.json")) as f:
                raw = f.read().strip()
            data = self._decode(raw) if raw else {"view": []}
            self.view = [tuple(entry) for entry in data["view"]]
        except FileNotFoundError:
            self.view = []
        # A message appended by another process after this view was saved.
        covered = sum(1 << level for level, _ in self.view)
        for i in range(covered, len(self.messages)):
            self.view.append((0, i))

    def _save_view(self) -> None:
        tmp = self._path("view.json.tmp")
        with open(tmp, "w") as f:
            f.write(self._encode({"view": [list(entry) for entry in self.view]}))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self._path("view.json"))

    def refresh(self) -> None:
        """Pick up what another process appended."""
        with self._lock:
            self.nodes.clear()
            self._load()

    def wipe(self) -> None:
        with self._lock:
            shutil.rmtree(self.dir, ignore_errors=True)
            self.messages, self.nodes, self.view = [], {}, []

    # ── the log ──────────────────────────────────────────────────────────

    @property
    def count(self) -> int:
        return len(self.messages)

    def append(self, kind: str, text: str, date: float | None = None) -> list[int]:
        """Log one message (several if it is long) and give its line(s) to the view."""
        if kind not in KINDS:
            raise ValueError(f"unknown kind {kind!r}")
        if kind == "echo":
            text = clip_tool_output(text)
        stamp = datetime.fromtimestamp(date or time.time(), timezone.utc).isoformat(timespec="seconds")
        with self._lock, self._file_lock():
            records = []
            for piece in split_message(text):
                i = len(self.messages) + len(records)
                records.append({"i": i, "kind": kind, "text": piece, "size": utf8_size(piece), "date": stamp})
            self._append_lines("messages.jsonl", records)
            self.messages.extend(records)
            self.view.extend((0, r["i"]) for r in records)
            self._save_view()
            return [r["i"] for r in records]

    def message(self, i: int) -> dict:
        return self.messages[i]

    # ── the tree ─────────────────────────────────────────────────────────

    def has_node(self, level: int, index: int) -> bool:
        return (level, index) in self.nodes

    def node(self, level: int, index: int) -> str | None:
        return self.nodes.get((level, index))

    def set_node(self, level: int, index: int, text: str) -> None:
        with self._lock, self._file_lock():
            if (level, index) in self.nodes:
                return
            self._append_lines("tree.jsonl", [{"l": level, "i": index, "text": text, "size": utf8_size(text)}])
            self.nodes[(level, index)] = text
            self._built.notify_all()

    def node_exists(self, level: int, index: int) -> bool:
        """The node covers only messages that exist."""
        return (index + 1) * (1 << level) <= self.count

    def missing_nodes(self) -> list[tuple[int, int]]:
        """Every node that could be built and is not, oldest first. Run once at start;
        afterwards the compactor queues each node as its sources appear."""
        missing = []
        level = 0
        while (1 << level) <= self.count:
            for index in range(self.count >> level):
                if (level, index) not in self.nodes:
                    missing.append((level, index))
            level += 1
        return missing

    def wait_built(self, upto: int, timeout: float) -> bool:
        """Wait until messages before `upto` all have their line."""
        deadline = time.monotonic() + timeout
        with self._built:
            while True:
                if all((0, i) in self.nodes for i in range(upto)):
                    return True
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self._built.wait(left)

    # ── the view ─────────────────────────────────────────────────────────

    def line(self, level: int, index: int) -> str:
        text = self.nodes.get((level, index))
        if text is None:
            text = "(not summarized yet: zoom it)"
        return f"{node_name(level, index)}|{text.replace(chr(10), ' ')}"

    def render(self, upto: int | None = None) -> str:
        """The view as lines, stopping at the first unbuilt line or at message `upto`."""
        lines = []
        with self._lock:
            for level, index in self.view:
                first = index << level
                if upto is not None and first >= upto:
                    break
                lines.append(self.line(level, index))
        return "\n".join(lines)

    def view_bytes(self) -> int:
        with self._lock:
            return sum(utf8_size(self.line(level, index)) + 1 for level, index in self.view)

    def merge(self, budget: int) -> int:
        """Once the view passes 2*budget, merge the most due sibling pairs whose parent is
        built until it is back under budget (or nothing more can merge yet).

        due = (T - last) / 2^l, how long ago the pair ended in its own line size:
        Taelin's rollback push with a bigger budget (gist, section 3.2). Ties go
        to the oldest pair.
        Returns the number of merges.
        """
        with self._lock:
            if self.view_bytes() <= 2 * budget and not getattr(self, "_shrinking", False):
                return 0
            self._shrinking = True
            total = self.count
            merges = 0
            while self.view_bytes() > budget:
                best = None
                for k in range(len(self.view) - 1):
                    (la, ia), (lb, ib) = self.view[k], self.view[k + 1]
                    if la != lb or ia % 2 or ib != ia + 1 or (la + 1, ia // 2) not in self.nodes:
                        continue
                    last = (ib + 1) * (1 << la) - 1
                    due = (total - last) / (1 << la)
                    if best is None or due > best[0]:
                        best = (due, k)
                if best is None:
                    break
                k = best[1]
                level, index = self.view[k]
                self.view[k : k + 2] = [(level + 1, index // 2)]
                merges += 1
            if self.view_bytes() <= budget:
                self._shrinking = False
            if merges:
                with self._file_lock():
                    self._save_view()
            return merges

    # ── zoom / date ──────────────────────────────────────────────────────

    def zoom(self, first: int, count: int) -> str:
        if count < 1 or count & (count - 1) or first % count:
            return f"error: {first}+{count} is not a line (n is a power of 2, id a multiple of n)"
        if first + count > self.count:
            return f"error: {first}+{count} goes past the last message ({self.count - 1})"
        if count == 1:
            m = self.messages[first]
            return f"{first}+1 [{m['kind']}, {m['date']}]\n{m['text']}"
        level = count.bit_length() - 1
        index = first // count
        return "\n".join(self.line(level - 1, 2 * index + k) for k in (0, 1))

    def date(self, i: int) -> str:
        if not 0 <= i < self.count:
            return f"error: no message {i}"
        return self.messages[i]["date"]
