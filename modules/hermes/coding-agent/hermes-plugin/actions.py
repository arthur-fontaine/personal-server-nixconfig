"""The broker's typed actions: what Pi asks Hermes for, decided by Hermes'
approval system (approval.py), then done here when allowed.

The sidecar has checked the session's token and each action's schema
(sidecar/broker.mjs); they are checked again here, since this side acts. Each
action is reviewed as the planned action ``sandbox_<action>`` {session,
...typed fields}, against the user's launching messages only, never Pi's
words (no action has a field for its reasons):

- request_host {host, method?, pathPrefix?}: a network grant asked ahead. The
  review clearing it at low risk grants it; otherwise the owner's buttons.
- request_folder {path}: a folder of this Mac, resolved here (the card shows
  the absolute path), copied read-only into the VM by the sidecar. Hermes'
  account reads only what it may.
- git_push {branch}: the session's own branch (sandbox/<id>, or
  sandbox/<id>-…), out of the VM as a bundle, fetched into the review clone
  and pushed from there to the repository's origin: host git with hooks off,
  never a checkout, never a force.
- ask_user {question, choices}: the owner's buttons, the question marked as
  Pi's; nothing to review, the owner is the one asked.
- shell {command, cwd?}: always the owner's buttons, whatever the review says
  (its view goes on the card). Runs as Hermes' account in a temporary
  directory (or cwd), with an environment rebuilt from nothing (no secret of
  /etc/hermes/secrets.env), a timeout, and its output cut and redacted.

The reply: {status: allowed|denied|timeout|error, by, reason, outcome,
result?, grant?, folder?}. by, reason and outcome go to the audit only; the
sidecar passes Pi only status and the result.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit, urlunsplit

from .approval import Approver, clean

logger = logging.getLogger(__name__)

MAX_OUTPUT = 4096
MAX_ASKS = 10
HOST = re.compile(r"(\*\.)?[a-z0-9.-]{1,253}")
METHOD = re.compile(r"[A-Z]{1,16}")
BRANCH = re.compile(r"sandbox/[A-Za-z0-9._/-]{1,200}")
BUNDLE = re.compile(r"push-[0-9]{1,6}\.bundle")
FIELDS = {
    "request_host": ({"host"}, {"method", "pathPrefix"}),
    "request_folder": ({"path"}, set()),
    "git_push": ({"branch"}, set()),
    "ask_user": ({"question", "choices"}, set()),
    "shell": ({"command"}, {"cwd"}),
}
# git on this side for a push: nothing of the repository's own may run, and
# no transport that is a program.
PUSH_GIT = [
    "git",
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "protocol.ext.allow=never",
]


class Invalid(Exception):
    pass


def check(action: str, args: Any) -> dict:
    if action not in FIELDS or not isinstance(args, dict):
        raise Invalid("unknown action")
    required, optional = FIELDS[action]
    if set(args) - required - optional or required - set(args):
        raise Invalid("fields")
    for key, value in args.items():
        if key == "choices":
            if (not isinstance(value, list) or not 2 <= len(value) <= 4
                    or not all(isinstance(c, str) and 0 < len(c) <= 64 for c in value) or len(set(value)) != len(value)):
                raise Invalid("choices")
        elif not isinstance(value, str) or not value or len(value) > 4000 or "\0" in value:
            raise Invalid(key)
    if action == "request_host" and (
            not HOST.fullmatch(args["host"]) or not METHOD.fullmatch(args.get("method") or "GET")
            or not (args.get("pathPrefix") or "/").startswith("/")):
        raise Invalid("grant")
    if action == "git_push" and (not BRANCH.fullmatch(args["branch"]) or ".." in args["branch"]):
        raise Invalid("branch")
    return args


def answer(status: str, by: str, reason: str = "", outcome: str = "", **fields) -> dict:
    return {"status": status, "by": by, "reason": reason, "outcome": outcome or status, **fields}


def from_choice(choice: str, timeout: float) -> dict | None:
    """The owner's refusals as replies; None for a choice that allows."""
    if choice == "deny":
        return answer("denied", "owner", "denied")
    if choice == "timeout":
        return answer("timeout", "timeout", f"no answer in {round(timeout)} s")
    if choice == "limit":
        return answer("denied", "limit", "too many questions open for this session")
    if choice == "unavailable" or choice is None:
        return answer("denied", "unavailable", "could not ask the owner")
    return None


def redact(text: str) -> str:
    """Hermes' own redaction (agent/redact.py, its patterns and the plugins'
    registered ones), forced on, failing closed."""
    try:
        from agent.redact import redact_for_egress

        return redact_for_egress(text)
    except Exception:  # noqa: BLE001
        try:
            from agent.redact import redact_sensitive_text

            return redact_sensitive_text(text, force=True)
        except Exception:  # noqa: BLE001
            return "[output withheld: the redaction is unavailable]"


def strip_credentials(url: str) -> str:
    """A remote as the owner and the reviewer see it: no user or password."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return url
    if not parts.scheme or "@" not in parts.netloc:
        return url
    return urlunsplit(parts._replace(netloc=parts.netloc.rsplit("@", 1)[1]))


def shell_env(env: dict, home: str, tmp: str) -> dict:
    """A command's environment, rebuilt from nothing: a path and a locale,
    never a variable of Hermes' (where the secrets file's keys are)."""
    return {
        "PATH": env.get("PATH") or "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": home,
        "TMPDIR": tmp,
        "LANG": env.get("LANG") or "en_US.UTF-8",
        "TERM": "dumb",
        "GIT_TERMINAL_PROMPT": "0",
    }


class Actions:
    def __init__(
        self,
        approver: Approver,
        *,
        state_dir: Path,
        sessions_dir: Path,
        safe_git: Callable[..., str],
        env: dict | None = None,
        shell_timeout: float = 120,
        home: str | None = None,
    ) -> None:
        self.approver = approver
        self.state_dir = Path(state_dir)
        self.sessions_dir = Path(sessions_dir)
        self.safe_git = safe_git
        self.env = os.environ if env is None else env
        self.shell_timeout = shell_timeout
        self.home = home or self.env.get("HOME") or str(Path.home())
        self.asks: dict[str, int] = {}

    def handle(self, session: dict, message: dict) -> dict:
        """session: {id, task, launch, repo, alive}; message: the sidecar's
        request {action, args, bundle?, base?}."""
        action = str(message.get("action") or "")
        try:
            args = check(action, message.get("args"))
        except Invalid as error:
            return answer("error", "policy", f"invalid action: {error}")
        return getattr(self, f"_{action}")(session, args, message)

    # The review, then the owner; `always_ask` keeps the review to the card.
    def _decide(self, session, tool, planned, title, lines, choices, *, always_ask=False, grant_low_only=True):
        note = ""
        if self.approver.auto_review:
            verdict, note = self.approver.verdict(session, tool, planned)
            if verdict is not None and verdict.run and not always_ask and (
                    not grant_low_only or verdict.risk == "low"):
                return "allowed", answer("allowed", "guard", verdict.reason)
        details = "\n".join([
            f"Pi, in sandbox session {session['id']}, asks Hermes {lines[0]}",
            "",
            f"Task: {clean(session.get('task'), 300)}",
            *lines[1:],
            *([note] if note else []),
        ])
        choice = self.approver.ask_owner(session, title, details, choices)
        refused = from_choice(choice, self.approver.timeout)
        if refused is not None:
            return None, refused
        return choice, answer("allowed", "owner", choice)

    def _request_host(self, session, args, message) -> dict:
        grant = {"host": args["host"].lower(), "method": (args.get("method") or "").upper() or None,
                 "pathPrefix": args.get("pathPrefix") or None}
        planned = {"session": session["id"], **{k: v for k, v in grant.items() if v}}
        what = f"{grant['method'] or 'any method'} {grant['host']}{grant['pathPrefix'] or ' (any path)'}"
        choice, reply = self._decide(
            session, "sandbox_request_host", planned, "Sandbox network access",
            ["for a network grant, ahead of its requests.", f"Grant: {clean(what, 300)}, for the session"],
            [("grant", "Grant it this session"), ("deny", "Deny")])
        if choice is None:
            return reply
        return {**reply, "outcome": "granted for the session", "grant": grant}

    def _resolve(self, path: str) -> Path | None:
        # ~ is Hermes' home (its account's, whatever HOME the plugin sees).
        if path == "~" or path.startswith("~/"):
            path = self.home + path[1:]
        candidate = Path(path)
        if not candidate.is_absolute():
            return None
        try:
            resolved = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            return None
        if not resolved.is_dir() or not os.access(resolved, os.R_OK | os.X_OK):
            return None
        return resolved

    def _request_folder(self, session, args, message) -> dict:
        resolved = self._resolve(args["path"])
        if resolved is None:
            # The same answer for a missing folder and a forbidden one.
            return answer("error", "policy", "not a folder Hermes can read", "nothing asked",
                          result={"error": "not a folder Hermes can read"})
        lines = ["for a read-only copy of a folder of this Mac.", f"Folder: {resolved}"]
        if str(resolved) != args["path"]:
            lines.append(f"(asked as {clean(args['path'], 300)})")
        lines.append("Copied once into the VM under /host, never written back.")
        choice, reply = self._decide(
            session, "sandbox_request_folder", {"session": session["id"], "path": str(resolved)},
            "Sandbox: a folder of this Mac", lines, [("copy", "Copy it in, read-only"), ("deny", "Deny")],
            grant_low_only=False)
        if choice is None:
            return reply
        if not session["alive"]():
            return answer("error", reply["by"], "the session ended first", "nothing copied")
        return {**reply, "outcome": "to copy", "folder": {"path": str(resolved)}}

    def _git_push(self, session, args, message) -> dict:
        sid, branch = session["id"], args["branch"]
        # The session's own branch only: sandbox/<id>, or sandbox/<id>-<name>.
        if not re.fullmatch(rf"sandbox/{re.escape(sid)}(-[A-Za-z0-9._-]{{1,100}})?", branch):
            return answer("denied", "policy", "not this session's branch", "refused",
                          result=None)
        repo = session.get("repo")
        if not repo:
            return answer("error", "policy", "no repository", result={"error": "the session has no repository"})
        bundle_name = str(message.get("bundle") or "")
        bundle = self.sessions_dir / sid / bundle_name
        if not BUNDLE.fullmatch(bundle_name) or not bundle.is_file():
            return answer("error", "error", "no bundle from the sidecar")
        try:
            remote = subprocess.run(
                ["git", "-c", "core.fsmonitor=false", "-C", str(Path(repo).expanduser()), "remote", "get-url", "origin"],
                capture_output=True, text=True, timeout=30, env={**self.env, "GIT_TERMINAL_PROMPT": "0"},
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            remote = ""
        if not remote:
            return answer("error", "policy", "no origin", result={"error": "the repository has no origin"})
        review = self.sessions_dir / sid / "review.git"
        try:
            head = self.fetch_review(review, bundle, branch)
            base = str(message.get("base") or "")
            span = f"{base}..{head}" if re.fullmatch(r"[0-9a-f]{40,64}", base) else head
            commits = int(self.safe_git(["rev-list", "--count", span], cwd=review).strip() or 0)
            stat = self.safe_git(["diff", "--no-ext-diff", "--no-textconv", "--shortstat",
                                  base if span != head else "4b825dc642cb6eb9a060e54bf8d69288fbee4904", head],
                                 cwd=review).strip()
        except Exception as error:  # noqa: BLE001
            logger.warning("sandbox %s: the push's bundle did not fetch: %s", sid, error)
            return answer("error", "error", "the bundle did not fetch")
        shown = strip_credentials(remote)
        choice, reply = self._decide(
            session, "sandbox_git_push",
            {"session": sid, "branch": branch, "remote": shown, "commits": commits},
            "Sandbox: push a branch",
            ["to push its branch to the repository's origin.",
             f"Repository: {repo}", f"Remote: {clean(shown, 300)}", f"Branch: {branch} at {head[:12]}",
             f"{commits} commit(s) since the session began{': ' + stat if stat else ''}",
             "A new branch or a fast-forward, never a force; the commits are Pi's: sandbox_result shows them."],
            [("push", "Push it"), ("deny", "Deny")], grant_low_only=False)
        if choice is None:
            return reply
        if not session["alive"]():
            return answer("error", reply["by"], "the session ended first", "not pushed")
        try:
            result = subprocess.run(
                [*PUSH_GIT, "-C", str(review), "push", "--no-verify", "--porcelain", remote,
                 f"refs/heads/{branch}:refs/heads/{branch}"],
                capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL,
                env={**self.env, "GIT_TERMINAL_PROMPT": "0"},
            )
        except (OSError, subprocess.SubprocessError) as error:
            return answer("error", reply["by"], f"push failed: {error}"[:300], "not pushed",
                          result={"error": "the push failed"})
        if result.returncode != 0:
            return answer("error", reply["by"], redact(result.stderr.strip())[-300:], "not pushed",
                          result={"error": "the push failed"})
        return {**reply, "outcome": f"pushed {head[:12]}"}

    def fetch_review(self, review: Path, bundle: Path, branch: str) -> str:
        if not review.exists():
            self.safe_git(["init", "--quiet", "--bare", str(review)])
        self.safe_git(["bundle", "verify", "--quiet", str(bundle)], cwd=review)
        self.safe_git(["fetch", "--quiet", "--no-tags", str(bundle), f"+refs/heads/{branch}:refs/heads/{branch}"],
                      cwd=review)
        return self.safe_git(["rev-parse", f"refs/heads/{branch}"], cwd=review).strip()

    def _ask_user(self, session, args, message) -> dict:
        sid = session["id"]
        count = self.asks.get(sid, 0)
        if count >= MAX_ASKS:
            return answer("denied", "limit", f"{MAX_ASKS} questions already asked in this session")
        self.asks[sid] = count + 1
        choices = [(f"c{i}", clean(c, 48)) for i, c in enumerate(args["choices"])] + [("deny", "Don't answer")]
        details = "\n".join([
            f"Pi, in sandbox session {sid}, asks you (its words, not Hermes'):",
            "",
            clean(args["question"].replace("\n", " "), 1000),
            "",
            f"Task: {clean(session.get('task'), 300)}",
        ])
        choice = self.approver.ask_owner(session, "Pi asks you", details, choices)
        refused = from_choice(choice, self.approver.timeout)
        if refused is not None:
            return refused
        if not (choice.startswith("c") and choice[1:].isdigit() and int(choice[1:]) < len(args["choices"])):
            return answer("denied", "unavailable", f"unexpected choice {choice!r}")
        picked = args["choices"][int(choice[1:])]
        return answer("allowed", "owner", "answered", result={"answer": picked})

    def _shell(self, session, args, message) -> dict:
        command = args["command"]
        cwd = None
        if args.get("cwd"):
            cwd = self._resolve(args["cwd"])
            if cwd is None:
                return answer("error", "policy", "not a folder Hermes can read", "nothing asked",
                              result={"error": "cwd: not a folder Hermes can read"})
        where = str(cwd) if cwd else "a new temporary folder"
        choice, reply = self._decide(
            session, "sandbox_shell", {"session": session["id"], "command": command, **({"cwd": str(cwd)} if cwd else {})},
            "Sandbox: a command on this Mac",
            ["to run a command on this Mac, as Hermes' account, without its secrets.",
             f"Command: {clean(command.replace(chr(10), ' ⏎ '), 1500)}",
             f"In: {where}", f"Stopped after {round(self.shell_timeout)} s; Pi gets the exit code and 4 KB of output."],
            [("run", "Run it once"), ("deny", "Deny")], always_ask=True)
        if choice is None:
            return reply
        if not session["alive"]():
            return answer("error", reply["by"], "the session ended first", "not run")
        return {**reply, **self._run(command, cwd)}

    def _run(self, command: str, cwd: Path | None) -> dict:
        shells = self.state_dir / "shell"
        shells.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = tempfile.mkdtemp(prefix="run-", dir=shells)
        try:
            process = subprocess.Popen(
                ["/bin/bash", "-c", command], cwd=str(cwd) if cwd else tmp, env=shell_env(self.env, self.home, tmp),
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
            )
            timed_out = False
            try:
                output, _ = process.communicate(timeout=self.shell_timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
                output, _ = process.communicate()
            text = redact(output.decode("utf-8", "replace"))
            if len(text) > MAX_OUTPUT:
                text = text[:MAX_OUTPUT - 1] + "…"
            result = {"exit_code": None if timed_out else process.returncode, "output": text,
                      **({"timed_out": True} if timed_out else {})}
            return {"outcome": "ran, timed out" if timed_out else f"ran, exit {process.returncode}", "result": result}
        except OSError as error:
            return {"status": "error", "outcome": "not run", "reason": str(error)[:300],
                    "result": {"error": "the command could not start"}}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
