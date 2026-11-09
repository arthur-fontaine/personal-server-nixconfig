"""What Hermes is doing, from its hooks (docs/app-protocol.md §2.1 `agent`)."""

from __future__ import annotations

import json
import threading
import time

from .protocol import cut, now_iso

STALE = 15 * 60  # a turn silent this long is gone (a crash between hooks)
ERROR_FOR = 10 * 60


def tool_label(tool_name: str, args) -> str:
    """"terminal: nix build …" — the tool and its first meaningful argument."""
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            args = {"input": args}
    first = ""
    if isinstance(args, dict):
        for key in ("command", "goal", "url", "query", "path", "file_path", "action", "prompt", "name", "text"):
            if isinstance(args.get(key), str) and args[key].strip():
                first = args[key].strip().split("\n")[0]
                break
    label = f"{tool_name}: {first}" if first else tool_name
    return cut(label, 80)


class Status:
    def __init__(self, on_change, owner_id=lambda: None):
        self.on_change = on_change
        self.owner_id = owner_id
        self.lock = threading.Lock()
        self.turns: dict[str, dict] = {}
        self.chats: dict[str, int] = {}
        self.error_until = 0.0
        self.error_chat = 0
        self.last_status = "idle"
        self.since = time.time()
        # (session, "done" | "failed" | "interrupted"), drained by the pet
        self.finished: list[tuple[str, str]] = []
        # Sessions whose turn ended. Hermes' background review (agent/background_review.py)
        # runs after the turn under the same session_id, firing pre_api_request and the tool
        # hooks but never on_session_end (its persistence is off): it would leave the session
        # "thinking" until STALE. Their hooks are ignored until a real turn begins
        # (pre_llm_call, which a fork doesn't fire).
        self.ended: set[str] = set()

    def chat_for(self, session_id: str) -> int:
        """The chat a session runs in: 0 for the main chat (and anything not a
        topic of the owner's DM), else the topic id. Read from the session's
        context vars while a turn runs, remembered per session."""
        try:
            from gateway.session_context import get_session_env

            chat_id = get_session_env("HERMES_SESSION_CHAT_ID")
            thread = get_session_env("HERMES_SESSION_THREAD_ID")
        except Exception:
            chat_id, thread = "", ""
        owner = self.owner_id()
        if chat_id:
            topic = 0
            if owner is not None and str(chat_id) == str(owner) and str(thread or "") not in ("", "1"):
                try:
                    topic = int(thread)
                except ValueError:
                    topic = 0
            if session_id:
                self.chats[session_id] = topic
            return topic
        return self.chats.get(session_id, 0)

    def _touch(self, session_id: str, status: str, task: str | None = None, **extra) -> None:
        key = session_id or "?"
        now = time.time()
        with self.lock:
            if key in self.ended:
                return
            turn = self.turns.get(key)
            if turn is None:
                turn = {"chat": self.chat_for(key), "started": now, "tools": 0}
                self.turns[key] = turn
            turn.update(status=status, at=now, **extra)
            if task is not None:
                turn["task"] = task
        self.on_change()

    # hooks
    def begin(self, session_id: str = "", **_) -> None:
        """pre_llm_call: a real turn starts (a background review never fires it)."""
        with self.lock:
            self.ended.discard(session_id or "?")

    def pre_api_request(self, session_id: str = "", **_) -> None:
        self._touch(session_id, "thinking")

    def pre_tool_call(self, tool_name: str = "", args=None, session_id: str = "", **_) -> None:
        with self.lock:
            turn = self.turns.get(session_id or "?")
            tools = (turn or {}).get("tools", 0) + 1
        self._touch(session_id, "working", tool_label(tool_name, args), tools=tools)

    def post_tool_call(self, session_id: str = "", **_) -> None:
        self._touch(session_id, "thinking")

    def human_input(self, session_id: str = "", waiting: bool = True) -> None:
        self._touch(session_id, "waiting_user" if waiting else "working")

    def end(self, session_id: str = "", failed: bool = False, interrupted: bool = False, **_) -> None:
        now = time.time()
        with self.lock:
            turn = self.turns.pop(session_id or "?", None)
            self.ended.add(session_id or "?")
            if len(self.ended) > 500:
                self.ended.clear()
            if failed and not interrupted:
                self.error_until = now + ERROR_FOR
                self.error_chat = (turn or {}).get("chat", 0)
            elif turn is not None:
                self.error_until = 0.0
            if turn is not None:
                outcome = "interrupted" if interrupted else "failed" if failed else "done"
                self.finished.append((session_id, outcome))
        self.on_change()

    def busy(self, chat: int) -> bool:
        """Whether a turn runs in ``chat`` (0 = the main chat)."""
        now = time.time()
        with self.lock:
            return any(t["chat"] == chat and now - t["at"] <= STALE for t in self.turns.values())

    def snapshot(self, questions_open: bool) -> dict:
        now = time.time()
        with self.lock:
            for key in [k for k, t in self.turns.items() if now - t["at"] > STALE]:
                del self.turns[key]
            turns = sorted(self.turns.values(), key=lambda t: t["at"])
            if questions_open or any(t["status"] == "waiting_user" for t in turns):
                status = "waiting_user"
            elif any(t["status"] == "working" for t in turns):
                status = "working"
            elif turns:
                status = "thinking"
            elif now < self.error_until:
                status = "error"
            else:
                status = "idle"
            latest = turns[-1] if turns else None
            if status != self.last_status:
                self.last_status, self.since = status, now
            chat = latest["chat"] if latest else (self.error_chat if status == "error" else 0)
            task = None
            if latest:
                task = latest.get("task") if latest["status"] != "thinking" else (latest.get("task") or "Thinking")
            progress = f"{latest['tools']} tool calls" if latest and latest.get("tools") else None
            return {"status": status, "chat": chat, "task": task, "progress": progress,
                    "since": now_iso(self.since), "busy_chats": sorted({t["chat"] for t in turns})}

    def take_finished(self) -> list[tuple[str, str]]:
        with self.lock:
            out, self.finished = self.finished, []
            return out
