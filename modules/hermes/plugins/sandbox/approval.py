"""Pi asks Hermes for access; Hermes' approval system decides.

Nothing inside the VM is approved: Pi's own commands, edits and tests run
freely there. A question reaches Hermes only at its boundary, when the
sidecar's network policy meets a request no grant of the session covers
(the grants are checked there first, and again for the requests that waited
on the same host's question). Then, as for one of Hermes' own tool calls:

1. With the auto-review on (server.hermes.decision.approval, guard loaded),
   guard's decision model reviews the request as the action
   ``sandbox_network`` {session, method, host, path}, against the user's own
   messages as guard held them when sandbox_run was called (never anything
   Pi wrote: its task as Hermes wrote it is a recent action, not the user's
   words). Cleared: the request runs, and at low risk its method and path
   prefix become a grant for the session.
2. Otherwise the owner gets buttons (owner_approval): once, this method and
   path prefix for the session, the whole host for the session, deny. No
   answer in time, or no Telegram, refuses.
"""

from __future__ import annotations

import logging
import re
import sys
import threading
from typing import Any, Callable

logger = logging.getLogger(__name__)

TOOL = "sandbox_network"
HOST = re.compile(r"[a-z0-9.-]{1,253}")
METHOD = re.compile(r"[A-Z]{1,16}")
MAX_TASK = 300
MAX_PATH = 300
# More questions than this open at once for a session are refused at once:
# Pi fanning out to many hosts must not flood the owner's chat.
MAX_OPEN = 4


def clean(text: Any, limit: int) -> str:
    """Printable, one line, cut: what the guest chose, shown to the owner."""
    text = "".join(c if c.isprintable() else "?" for c in str(text or ""))
    return text if len(text) <= limit else text[:limit] + "…"


def grant_prefix(path: str) -> str:
    """The path prefix a "method + path" grant covers: the request's
    directory (/simple/requests/ gives /simple), or the path itself when
    that would be the root."""
    segments = [s for s in path.split("/") if s]
    if len(segments) < 2:
        return path or "/"
    return "/" + "/".join(segments[:-1])


def _owner_ask(title: str, details: str, choices, timeout: float) -> str:
    try:
        from owner_approval import ask
    except ImportError:
        logger.warning("sandbox: owner_approval is not loaded: refusing %s", title)
        return "unavailable"
    return ask(title, details, choices, timeout=timeout)


def _guard_review(context: dict | None, tool: str, args: dict, actions: list[str]):
    guard = sys.modules.get("guard")
    if guard is None or getattr(guard, "GUARD", None) is None:
        return None
    return guard.review_action(context or {}, tool, args, actions)


def deny(by: str, reason: str) -> dict:
    return {"allow": False, "by": by, "reason": reason}


class Approver:
    def __init__(
        self,
        *,
        auto_review: bool,
        timeout: float = 300,
        ask: Callable[..., str] = _owner_ask,
        review: Callable[..., Any] = _guard_review,
    ) -> None:
        self.auto_review = auto_review
        self.timeout = timeout
        self.ask = ask
        self.review = review
        self.open: dict[str, int] = {}
        self.lock = threading.Lock()

    def decide(self, session: dict, question: dict) -> dict:
        """session: {id, task, launch}; question: the sidecar's request.
        Returns the reply's fields: allow, by, reason, and maybe grant."""
        host = str(question.get("host") or "").lower()
        method = str(question.get("method") or "").upper()
        path = str(question.get("path") or "")
        scheme = "http" if question.get("scheme") == "http" else "https"
        if not HOST.fullmatch(host) or not METHOD.fullmatch(method) or not path.startswith("/"):
            return deny("policy", "malformed request")
        ambiguous = bool(question.get("ambiguous"))
        request = {"session": session["id"], "method": method, "host": host, "path": clean(path, MAX_PATH)}
        review_note = ""
        # An ambiguous path (an encoded "/", "\" or ".") is the owner's to
        # judge: what the server reads is not what a reviewer would see.
        if self.auto_review and not ambiguous:
            actions = [f"sandbox_run (session {session['id']}): {clean(session.get('task'), 500)}"]
            try:
                verdict = self.review(session.get("launch"), TOOL, request, actions)
            except Exception as error:  # noqa: BLE001
                logger.warning("sandbox: the auto-review failed: %s", error)
                verdict = None
            if verdict is not None and verdict.run:
                answer = {"allow": True, "by": "guard", "reason": verdict.reason}
                if verdict.risk == "low":
                    answer["grant"] = {"host": host, "method": method, "pathPrefix": grant_prefix(path)}
                return answer
            review_note = f"Auto-review: {verdict.reason}." if verdict is not None else "Auto-review unavailable."
        return self._ask_owner(session, request, scheme, ambiguous, review_note, path)

    def _ask_owner(self, session, request, scheme, ambiguous, review_note, path) -> dict:
        sid = session["id"]
        with self.lock:
            if self.open.get(sid, 0) >= MAX_OPEN:
                return deny("limit", f"{MAX_OPEN} questions already open for this session")
            self.open[sid] = self.open.get(sid, 0) + 1
        try:
            method, host = request["method"], request["host"]
            prefix = grant_prefix(path)
            choices = [("once", "Once")]
            if not ambiguous:
                choices.append(("path", clean(f"{method} {prefix} this session", 48)))
            choices += [("host", clean(f"All of {host} this session", 48)), ("deny", "Deny")]
            lines = [
                f"Pi, in sandbox session {sid}, asks Hermes for access to a host it has no grant for.",
                "",
                f"Task: {clean(session.get('task'), MAX_TASK)}",
                f"Request: {method} {scheme}://{host}{request['path']}",
            ]
            if ambiguous:
                lines.append('The path holds an encoded "/", "\\" or ".": only once or the whole host.')
            if review_note:
                lines.append(review_note)
            choice = self.ask("Sandbox network access", "\n".join(lines), choices, self.timeout)
        finally:
            with self.lock:
                self.open[sid] -= 1
                if not self.open[sid]:
                    del self.open[sid]
        if choice == "once":
            return {"allow": True, "by": "owner", "reason": "once"}
        if choice == "path" and not ambiguous:
            return {"allow": True, "by": "owner", "reason": "method and path for the session",
                    "grant": {"host": host, "method": method, "pathPrefix": prefix}}
        if choice == "host":
            return {"allow": True, "by": "owner", "reason": "host for the session", "grant": {"host": host}}
        if choice == "timeout":
            return deny("timeout", f"no answer in {round(self.timeout)} s")
        if choice == "deny":
            return deny("owner", "denied")
        return deny("unavailable", f"could not ask the owner ({choice})")
