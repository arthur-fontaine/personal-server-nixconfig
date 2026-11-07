"""front_desk: the owner's main Telegram chat answers and dispatches; long work
runs in background subagents.

A Telegram chat is one queue: while a turn runs, what the user sends waits for
it (or, with busy_input_mode steer, for its next tool boundary). A turn that
watched a build for hours left every message unanswered for hours. So a turn
of the main chat (the root of the owner's DM with the bot) gets a budget, and
past it every tool call is blocked but the ones that answer or dispatch: the
block tells Hermes to hand the rest to ``delegate_task``, whose top-level
calls run in the background and post their result as a new message
(website/docs/user-guide/features/delegation.md, at the pinned revision).

- The budget is a number of tool calls and a wall-clock time from the turn's
  start (config.json, written by agent/front-desk.nix), the time spent waiting
  on the user (an approval card, a clarify question) not counted.
- A foreground ``terminal`` call that may run long (a timeout above
  ``foreground_seconds``, or a build, an install, a test run) becomes a
  background one that notifies when it exits (``pre_tool_call``'s ``modify``,
  website/docs/user-guide/features/hooks.md): its result comes back as a new
  message, and the turn ends meanwhile.

Only the main chat's own turns: ``pre_llm_call`` marks a session's turn as
the front desk's when its platform is Telegram, it has no parent session (a
``delegate_task`` child runs as platform ``subagent`` with its parent's id,
tools/delegate_tool.py) and the gateway session it runs in is the owner's DM,
outside any topic. Sub-chats (topics, groups), the events' webhook turns, cron
and the CLI are never capped, and nor is a subagent, which has a session of
its own and so never matches the turn recorded for its parent.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULTS = {"seconds": 120, "tool_calls": 8, "foreground_seconds": 60}

# What a turn may still do past its budget, and what never counts towards it:
# dispatching, talking to the user, recalling, finding a tool. Each is one
# quick step, and they are what "hand it over and say so" needs.
EXEMPT = frozenset({
    "delegate_task",
    # The user: a question with buttons (clarify, owner_approval's propose),
    # a message, a reaction.
    "clarify", "propose", "send_message", "react_to_message",
    # Recall: unii's view of the chat (zoom, date), Hermes' own memory and
    # session search, the todo list.
    "zoom", "date", "memory", "session_search", "todo_list",
    # Deferred tools are reached through these (tools/tool_search.py):
    # process_manage, todo_list, session_search are deferred by default.
    "tool_search", "tool_describe",
})
# process_manage's actions that return at once (tools/process_registry.py,
# the schema's enum): checking on or stopping a background job is what the
# user asks the front desk for. Not "wait", which blocks.
PROCESS_QUICK = frozenset({"list", "poll", "log", "kill", "close"})

# A command's position: the start, or after ; & | ( or $(, past sudo/env/time
# and VAR=value prefixes.
_AT = r"(?:^|[;&|(\n]|\$\()\s*(?:(?:sudo|time|nice|env|caffeinate|taskpolicy\s+-c\s+\w+)\s+(?:-\S+\s+)*|\w+=\S*\s+)*"
# Commands that usually outlast a minute: builds, rebuilds, installs, test
# suites, clones. Any "<tool> build" too (the nx2apple build Hermes watched for
# hours), but for the commands that only print the word.
LONG = re.compile(_AT + "(?:" + "|".join([
    r"(?:darwin-rebuild|server-rebuild|nixos-rebuild|xcodebuild|nix-build|pytest|ffmpeg|rsync)\b",
    r"nix\s+(?:build|flake\s+(?:check|update)|develop|copy|profile\s+(?:install|upgrade))\b",
    r"(?:swift|cargo|go|gradle|\./gradlew|mvn|dotnet|bazel|zig)\s+(?:build|test|install)\b",
    r"(?:make|ninja|cmake\s+--build)\b",
    r"(?:pnpm|npm|yarn|bun)\s+(?:install|i|ci|add|build|test|run\s+(?:build|test))\b",
    r"(?:pip3?\s+install|uv\s+(?:sync|pip\s+install)|poetry\s+install)\b",
    r"brew\s+(?:install|upgrade|reinstall)\b",
    r"docker\s+(?:build|pull|compose\s+(?:up|build))\b",
    r"git\s+clone\b",
    r"(?!(?:echo|printf|cat|less|head|tail|grep|rg|ls|man|which|type|file)\b)[\w./-]+\s+(?:build|rebuild|archive)\b",
]) + ")", re.MULTILINE)
SLEEP = re.compile(_AT + r"sleep\s+(\d+)", re.MULTILINE)

ROOT_THREADS = {"", "1"}  # Telegram's General topic arrives as no thread or "1"


def owner_id() -> str | None:
    # The owner's DM: its chat id is their user id, the first of
    # TELEGRAM_ALLOWED_USERS (as lost_turns and owner_approval read it).
    first = os.environ.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()
    return first if first.lstrip("-").isdigit() else None


def main_dm(session_key: str, owner: str | None) -> bool:
    """``agent:<ns>:telegram:dm:<chat_id>[:<thread_id>]`` (gateway/session.py,
    build_session_key), the root of the owner's DM."""
    parts = (session_key or "").split(":")
    if len(parts) < 5 or parts[0] != "agent" or parts[2:4] != ["telegram", "dm"]:
        return False
    thread = parts[5] if len(parts) > 5 else ""
    return thread in ROOT_THREADS and (owner is None or parts[4] == owner)


def current_session_key() -> str:
    try:
        from gateway.session_context import bound_session_key, get_session_env
        return bound_session_key() or get_session_env("HERMES_SESSION_KEY", "")
    except Exception:
        return ""


def runs_long(args: dict, foreground_seconds: int) -> bool:
    """A foreground terminal call that may hold the turn longer than
    ``foreground_seconds``."""
    if args.get("background"):
        return False
    timeout = args.get("timeout")
    if isinstance(timeout, (int, float)) and not isinstance(timeout, bool) and timeout > foreground_seconds:
        return True
    command = str(args.get("command") or "")
    if LONG.search(command):
        return True
    return any(int(n) > foreground_seconds for n in SLEEP.findall(command))


def exempt(tool_name: str, args: dict) -> bool:
    if tool_name == "process_manage":
        return args.get("action") in PROCESS_QUICK
    return tool_name in EXEMPT


@dataclass
class Turn:
    turn_id: str
    session_key: str
    started: float
    calls: int = 0
    paused: float = 0.0  # seconds spent waiting on the user
    waits: dict = field(default_factory=dict)  # request id -> since

    def elapsed(self, now: float) -> float:
        return now - self.started - self.paused - sum(now - since for since in self.waits.values())


class FrontDesk:
    def __init__(self, seconds: float = DEFAULTS["seconds"], tool_calls: int = DEFAULTS["tool_calls"],
                 foreground_seconds: int = DEFAULTS["foreground_seconds"], clock=time.monotonic) -> None:
        self.seconds = seconds
        self.tool_calls = tool_calls
        self.foreground_seconds = foreground_seconds
        self.clock = clock
        self.turns: dict[str, Turn] = {}
        self.lock = threading.Lock()

    def pre_llm_call(self, session_id: str = "", turn_id: str = "", platform: str = "",
                     parent_session_id: str = "", **_):
        key = current_session_key()
        with self.lock:
            if platform == "telegram" and not parent_session_id and main_dm(key, owner_id()):
                self.turns[session_id] = Turn(turn_id, key, self.clock())
            else:
                self.turns.pop(session_id, None)
        return None

    def _turn(self, session_id: str, turn_id: str) -> Turn | None:
        turn = self.turns.get(session_id or "")
        # A turn that never went through pre_llm_call (none recorded, or an
        # older one) is not known to be the front desk's.
        return turn if turn is not None and turn.turn_id == turn_id else None

    def pre_tool_call(self, tool_name: str = "", args: dict | None = None, session_id: str = "",
                      turn_id: str = "", **_):
        args = args if isinstance(args, dict) else {}
        with self.lock:
            turn = self._turn(session_id, turn_id)
            if turn is None or exempt(tool_name, args):
                return None
            turn.calls += 1
            elapsed = turn.elapsed(self.clock())
            within = turn.calls <= self.tool_calls and elapsed <= self.seconds
        if within and tool_name == "terminal" and runs_long(args, self.foreground_seconds):
            logger.info("front_desk: a long foreground command goes to the background: %s",
                        str(args.get("command"))[:120])
            # `notify` is the advertised argument (tools/terminal_tool.py,
            # TERMINAL_SCHEMA): true sends one notification when it exits.
            return {"action": "modify", "args": {"background": True, "notify": True}}
        if within:
            return None
        logger.info("front_desk: %s blocked in the main chat (%d calls, %.0fs)", tool_name, turn.calls, elapsed)
        return {"action": "block", "message": self.block_message(tool_name, turn.calls, elapsed)}

    def block_message(self, tool_name: str, calls: int, elapsed: float) -> str:
        return (
            f"Not run: {tool_name}. This turn of the main chat is past its budget "
            f"({self.tool_calls} tool calls or {self.seconds:.0f} s; it is at {calls} calls, {elapsed:.0f} s), "
            "and while it runs, the user's messages wait. Hand the rest of this work to delegate_task now, "
            "in one call: a goal and a context complete enough for a subagent that saw nothing of this chat "
            "(what the user asked, what you found so far, the paths, commands and accounts involved, and "
            "what done means). Then tell the user in a sentence or two what you launched, and end your "
            "turn: its result comes back as a new message. Until the turn ends, only delegate_task, "
            "clarify, propose, messages, memory and recall, and process_manage list/poll/log/kill run."
        )

    # The time a turn waits on the user is not the turn's: an approval card
    # or a clarify question (tools/human_input_hooks.py).
    def _waiting(self, session_id: str, session_key: str) -> Turn | None:
        turn = self.turns.get(session_id or "")
        if turn is None and session_key:
            turn = next((t for t in self.turns.values() if t.session_key == session_key), None)
        return turn

    def on_human_input_request(self, request_id: str = "", session_id: str = "", session_key: str = "", **_):
        with self.lock:
            if (turn := self._waiting(session_id, session_key)) is not None:
                turn.waits[request_id] = self.clock()

    def on_human_input_resolved(self, request_id: str = "", session_id: str = "", session_key: str = "", **_):
        with self.lock:
            if (turn := self._waiting(session_id, session_key)) is not None:
                since = turn.waits.pop(request_id, None)
                if since is not None:
                    turn.paused += self.clock() - since


def load(home: str) -> FrontDesk:
    path = Path(home) / "front_desk" / "config.json"
    config = {**DEFAULTS, **(json.loads(path.read_text()) if path.exists() else {})}
    return FrontDesk(float(config["seconds"]), int(config["tool_calls"]), int(config["foreground_seconds"]))


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    desk = load(str(get_hermes_home()))
    ctx.register_hook("pre_llm_call", desk.pre_llm_call)
    ctx.register_hook("pre_tool_call", desk.pre_tool_call)
    ctx.register_hook("on_human_input_request", desk.on_human_input_request)
    ctx.register_hook("on_human_input_resolved", desk.on_human_input_resolved)
