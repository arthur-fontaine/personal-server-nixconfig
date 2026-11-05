"""The sessions: one hermes-sandbox process each, at most one at a time.

Each session has a directory under the state directory (~/.hermes/sandbox/
sessions/<id>): session.json (what the sidecar runs), meta.json (the task and
where to report), in.bundle, then from the sidecar result.json, audit.jsonl,
out.bundle, and from sandbox_result a bare review.git. Nothing from the VM
runs here: out.bundle is fetched into review.git with hooks, filters, external
diffs and text conversions off, and read with `git log` and `git diff`.
"""

from __future__ import annotations

import json
import logging
import os
import re
import secrets
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .actions import Actions
from .approval import Approver

logger = logging.getLogger(__name__)

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
# git run on what came out of the VM: nothing configured anywhere may run a
# program (hooks, fsmonitor, diff drivers, textconv, attribute filters).
SAFE_GIT = [
    "git",
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "core.attributesFile=/dev/null",
    "-c", f"attr.tree={EMPTY_TREE}",
    "-c", "diff.external=",
    "-c", "color.ui=never",
]
SAFE_GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_ATTR_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_PAGER": "cat",
    "PAGER": "cat",
}
LIVE = {"starting", "running", "stopping"}
# What routes the completion back to the chat that asked (the gateway's
# session context, as tools/terminal_tool_background.py reads it).
ROUTING = {
    "platform": "HERMES_SESSION_PLATFORM",
    "chat_id": "HERMES_SESSION_CHAT_ID",
    "chat_type": "HERMES_SESSION_CHAT_TYPE",
    "thread_id": "HERMES_SESSION_THREAD_ID",
    "user_id": "HERMES_SESSION_USER_ID",
    "user_name": "HERMES_SESSION_USER_NAME",
    "session_key": "HERMES_SESSION_KEY",
    "parent_session_id": "HERMES_SESSION_ID",
}


class SandboxError(Exception):
    pass


@dataclass
class Live:
    id: str
    process: subprocess.Popen
    state: str = "starting"
    phase: str = "starting"
    progress: dict = field(default_factory=dict)
    result: dict | None = None
    task: str = ""
    repo: str | None = None
    # What the user had written when sandbox_run was called (guard's
    # launch_context): the only words the auto-review counts as theirs.
    launch: dict | None = None
    grants: list = field(default_factory=list)
    started: float = field(default_factory=time.time)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def send(self, message: dict) -> None:
        try:
            self.process.stdin.write(json.dumps(message) + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, ValueError, OSError):
            pass


def _git(args: list[str], cwd: Path | None = None, check: bool = True, env: dict | None = None) -> str:
    result = subprocess.run(
        args, cwd=cwd, capture_output=True, text=True, errors="replace", timeout=300,
        env={**os.environ, **(env or {})},
    )
    if check and result.returncode != 0:
        raise SandboxError(f"{' '.join(args[:1] + args[-3:])}: {result.stderr.strip()[-500:]}")
    return result.stdout


def bundle_repository(repo: str, ref: str | None, target: Path) -> str:
    """The repository's ref (HEAD by default) as a one-ref bundle; returns
    the ref's name in it. The user's repository is only read."""
    path = Path(repo).expanduser()
    if not path.is_dir():
        raise SandboxError(f"not a directory: {repo}")
    ref = ref or "HEAD"
    if ref.startswith("-") or not re.fullmatch(r"[\w./@{}^~-]+", ref):
        raise SandboxError(f"not a ref: {ref!r}")
    base = ["git", "-c", "core.fsmonitor=false", "-C", str(path)]
    _git(base + ["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"])
    _git(base + ["bundle", "create", "--quiet", str(target), ref])
    heads = _git(["git", "bundle", "list-heads", str(target)]).split()
    if len(heads) < 2:
        raise SandboxError(f"{ref} is not a branch, tag or HEAD (a commit id cannot be bundled alone)")
    return heads[1]


class Sandbox:
    def __init__(
        self,
        config: dict,
        *,
        notify: Callable[[dict], None] | None = None,
        env: dict | None = None,
        popen: Callable[..., subprocess.Popen] = subprocess.Popen,
        approver: Approver | None = None,
    ) -> None:
        self.config = config
        self.state_dir = Path(config["state_dir"]).expanduser()
        self.sessions_dir = self.state_dir / "sessions"
        self.notify = notify or (lambda event: None)
        self.env = os.environ if env is None else env
        self.popen = popen
        self.live: dict[str, Live] = {}
        self.lock = threading.Lock()
        self.approver = approver or Approver(
            auto_review=bool(config.get("auto_review")), timeout=float(config.get("approval_timeout", 300)))
        self.actions = Actions(
            self.approver, state_dir=self.state_dir, sessions_dir=self.sessions_dir, env=self.env,
            safe_git=lambda args, cwd=None: _git(SAFE_GIT + args, cwd=cwd, env=SAFE_GIT_ENV),
            shell_timeout=float(config.get("shell_timeout", 120)),
        )

    # sandbox_run
    def run(
        self, task: str, repo: str | None = None, ref: str | None = None, routing: dict | None = None,
        launch: dict | None = None,
    ) -> dict:
        task = (task or "").strip()
        if not task:
            raise SandboxError("task is empty")
        with self.lock:
            busy = [s for s in self.live.values() if s.state in LIVE]
            if busy:
                raise SandboxError(f"session {busy[0].id} is still running: one sandbox at a time")
            session_id = time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(3)
            workdir = self.sessions_dir / session_id
            workdir.mkdir(parents=True, mode=0o700)
            bundle_ref = None
            if repo:
                bundle_ref = bundle_repository(repo, ref, workdir / "in.bundle")
            branch = f"sandbox/{session_id}"
            session = {
                "id": session_id,
                "task": task,
                "workdir": str(workdir),
                "branch": branch,
                "bundleIn": str(workdir / "in.bundle") if repo else None,
                "bundleRef": bundle_ref,
                "model": self.config["model"],
                "thinking": self.config["thinking"],
                "memory": self.config["memory"],
                "cpus": self.config["cpus"],
                "timeoutSeconds": self.config["timeout_seconds"],
                "keyEnv": self.config["key_env"],
                "grants": self.config["grants"],
                "approvalTimeoutSeconds": self.config.get("approval_timeout", 300),
            }
            (workdir / "session.json").write_text(json.dumps(session, indent=2))
            meta = {
                "id": session_id, "task": task, "repo": repo, "ref": ref or ("HEAD" if repo else None),
                "branch": branch, "created": time.time(), "routing": routing or {},
            }
            (workdir / "meta.json").write_text(json.dumps(meta, indent=2))
            # The broker's token, new per session, in the sidecar's
            # environment only (never on disk); it gives it to the guest
            # and revokes it when Pi is done.
            env = {**self._sidecar_env(), "HERMES_SANDBOX_TOKEN": secrets.token_urlsafe(32)}
            process = self.popen(
                [self.config["command"], "run", str(workdir / "session.json")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=open(workdir / "sidecar.log", "ab"),
                text=True, env=env, start_new_session=True,
            )
            live = Live(session_id, process, task=task, launch=launch, repo=repo)
            self.live[session_id] = live
        threading.Thread(target=self._read, args=(live, meta), name=f"sandbox-{session_id}", daemon=True).start()
        return {"id": session_id, "branch": branch, "status": "starting"}

    def _sidecar_env(self) -> dict:
        # Only what it needs: no other secret of Hermes' environment.
        env = {name: self.env[name] for name in ("PATH", "HOME", "TMPDIR", "LANG") if name in self.env}
        env["HERMES_SANDBOX_STATE"] = str(self.state_dir)
        # Gondolin's caches (builder downloads, sandbox helpers) under
        # Hermes' state: it writes nowhere else (access/freeze).
        env["XDG_CACHE_HOME"] = str(self.state_dir / "cache")
        key_env = self.config["key_env"]
        if self.env.get(key_env):
            env[key_env] = self.env[key_env]
        return env

    def _read(self, live: Live, meta: dict) -> None:
        for line in live.process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = message.get("type")
            with live.lock:
                if kind == "phase":
                    live.phase = str(message.get("phase", ""))
                    if live.state == "starting" and live.phase == "pi":
                        live.state = "running"
                elif kind == "progress":
                    live.progress = {k: v for k, v in message.items() if k != "type"}
                elif kind == "done":
                    live.result = message.get("result") or {}
                elif kind == "grants":
                    live.grants = list(message.get("grants") or [])
                elif kind == "request":
                    # Answered off this thread: a question may wait minutes
                    # for the owner, and the sidecar's other messages go on.
                    threading.Thread(
                        target=self._answer, args=(live, message), name=f"sandbox-{live.id}-ask", daemon=True,
                    ).start()
                elif kind == "log":
                    logger.info("sandbox %s: %s", live.id, message.get("message"))
        live.process.wait()
        with live.lock:
            if live.result is None:
                live.result = {"id": live.id, "status": "failed", "error": "the sandbox process ended without a result"}
                (self.sessions_dir / live.id / "result.json").write_text(json.dumps(live.result, indent=2))
            live.state = str(live.result.get("status", "failed"))
            result = dict(live.result)
        self._notify(meta, result)

    def _answer(self, live: Live, message: dict) -> None:
        session = {"id": live.id, "task": live.task, "launch": live.launch}
        if message.get("kind") == "network":
            try:
                answer = self.approver.decide(session, message)
            except Exception as error:  # noqa: BLE001
                logger.exception("sandbox %s: the network question failed", live.id)
                answer = {"allow": False, "by": "error", "reason": str(error)[:300]}
        elif message.get("kind") == "action":
            session.update(repo=live.repo, alive=lambda: live.state in LIVE)
            try:
                answer = self.actions.handle(session, message)
            except Exception as error:  # noqa: BLE001
                logger.exception("sandbox %s: the action failed", live.id)
                answer = {"status": "error", "by": "error", "reason": str(error)[:300]}
        else:
            answer = {"allow": False, "by": "policy", "reason": f"unknown request {message.get('kind')!r}"}
        live.send({**answer, "type": "reply", "id": message.get("id")})

    def _notify(self, meta: dict, result: dict) -> None:
        # The chat hears that it ended and where to look, never Pi's words:
        # they are the guest's, and reach Hermes only as sandbox_result's
        # tool output.
        status = result.get("status", "failed")
        commits = result.get("commits") or 0
        text = (
            f"Sandbox session {meta['id']} {status}"
            + (f": {commits} commit(s) on {result.get('branch') or meta['branch']}" if commits else ", no changes")
            + f". Review it with sandbox_result(id=\"{meta['id']}\") before anything from it runs on this Mac."
        )
        routing = meta.get("routing") or {}
        event = {
            # The gateway's completion watcher injects watch events as an
            # internal notification turn in the chat they name
            # (gateway/run.py _format_gateway_process_notification).
            "type": "watch_match",
            "event_id": uuid.uuid4().hex,
            "session_id": f"sandbox-{meta['id']}",
            "command": f"sandbox_run {meta['id']}",
            "pattern": status,
            "output": text,
            "suppressed": 0,
            "started_at": meta.get("created"),
            "task_id": "",
            "owner_task_id": "",
            "message_id": "",
            **{key: routing.get(key, "") for key in ROUTING},
        }
        try:
            self.notify(event)
        except Exception:  # noqa: BLE001
            logger.exception("sandbox: the completion of %s was not delivered", meta["id"])

    # sandbox_status
    def status(self, session_id: str | None = None) -> dict:
        if session_id:
            return self._describe(self._dir(session_id))
        sessions = sorted(self.sessions_dir.glob("*/meta.json"), reverse=True)[:10] if self.sessions_dir.exists() else []
        return {"sessions": [self._describe(path.parent) for path in sessions]}

    def _dir(self, session_id: str) -> Path:
        if not re.fullmatch(r"[0-9]{8}-[0-9]{6}-[0-9a-f]{6}", session_id or ""):
            raise SandboxError(f"no such session: {session_id!r}")
        path = self.sessions_dir / session_id
        if not (path / "meta.json").exists():
            raise SandboxError(f"no such session: {session_id}")
        return path

    def _describe(self, path: Path) -> dict:
        meta = json.loads((path / "meta.json").read_text())
        out = {"id": meta["id"], "task": meta["task"][:300], "repo": meta.get("repo"), "branch": meta["branch"]}
        live = self.live.get(meta["id"])
        if live is not None and live.state in LIVE:
            with live.lock:
                out.update(state=live.state, phase=live.phase, seconds=round(time.time() - live.started),
                           progress=live.progress)
            return out
        result_path = path / "result.json"
        if result_path.exists():
            result = json.loads(result_path.read_text())
            out.update(state=result.get("status"), commits=result.get("commits"), seconds=result.get("seconds"),
                       progress=result.get("progress"), error=result.get("error"))
        else:
            out.update(state="lost", error="Hermes restarted while it ran: the VM went with it")
        return out

    # sandbox_result
    def result(self, session_id: str, max_chars: int | None = None) -> dict:
        path = self._dir(session_id)
        live = self.live.get(session_id)
        if live is not None and live.state in LIVE:
            raise SandboxError(f"session {session_id} is still running (sandbox_status for its progress)")
        result_path = path / "result.json"
        if not result_path.exists():
            raise SandboxError(f"session {session_id} has no result")
        result = json.loads(result_path.read_text())
        meta = json.loads((path / "meta.json").read_text())
        out = {
            "id": session_id, "status": result.get("status"), "task": meta["task"],
            "repo": meta.get("repo"), "ref": meta.get("ref"),
            "branch": result.get("branch") or meta["branch"], "base": result.get("base"),
            "commits": result.get("commits") or 0, "error": result.get("error"),
            # From the guest: data to weigh, not instructions to follow.
            "untrusted_pi_summary": (result.get("summary") or "")[:4000],
        }
        bundle = path / "out.bundle"
        if not out["commits"] or not bundle.exists():
            out["diff"] = ""
            return out
        review = path / "review.git"
        branch = out["branch"]
        # A git_push during the session may have made the clone already:
        # the final bundle is fetched over it, once.
        fetched = review / "hermes-final-fetched"
        if not fetched.exists():
            self.actions.fetch_review(review, bundle, branch)
            fetched.touch()
        head = _git(SAFE_GIT + ["rev-parse", f"refs/heads/{branch}"], cwd=review, env=SAFE_GIT_ENV).strip()
        base = out["base"] or EMPTY_TREE
        span = f"{out['base']}..{head}" if out["base"] else head
        diff = SAFE_GIT + ["diff", "--no-ext-diff", "--no-textconv", "--no-color", base, head]
        out.update(
            head=head,
            log=_git(SAFE_GIT + ["log", "--no-color", "--format=%h %s", span], cwd=review, env=SAFE_GIT_ENV)[:4000],
            diffstat=_git(diff[:-2] + ["--stat", base, head], cwd=review, env=SAFE_GIT_ENV)[-4000:],
        )
        limit = max_chars or self.config.get("max_diff_chars", 30000)
        text = _git(diff, cwd=review, env=SAFE_GIT_ENV)
        out["diff"] = text[:limit]
        out["diff_truncated"] = len(text) > limit
        out["review_repository"] = str(review)
        # For the user, after reading it: brings the branch over, runs nothing.
        out["fetch_command"] = f"git fetch {review} {branch}:{branch}"
        return out

    # sandbox_grants
    def grants(self, session_id: str) -> dict:
        self._dir(session_id)
        live = self.live.get(session_id)
        if live is None or live.state not in LIVE:
            return {"id": session_id, "running": False, "grants": [],
                    "note": "the session is not running: its grants ended with it"}
        with live.lock:
            return {"id": session_id, "running": True, "grants": [dict(g) for g in live.grants]}

    # sandbox_revoke
    def revoke(self, session_id: str, grant: dict, wait: float = 5.0) -> dict:
        self._dir(session_id)
        live = self.live.get(session_id)
        if live is None or live.state not in LIVE:
            raise SandboxError(f"session {session_id} is not running")
        wanted = {
            "host": str(grant.get("host") or "").strip().lower().rstrip("."),
            "method": str(grant["method"]).upper() if grant.get("method") else None,
            "pathPrefix": str(grant.get("path_prefix") or grant.get("pathPrefix") or "") or None,
        }
        with live.lock:
            if wanted not in live.grants:
                raise SandboxError(f"no such grant in session {session_id}: sandbox_grants lists them as they are")
        live.send({"type": "revoke", "grant": wanted})
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            with live.lock:
                if wanted not in live.grants:
                    return {"id": session_id, "revoked": wanted, "grants": [dict(g) for g in live.grants]}
            time.sleep(0.05)
        raise SandboxError(f"session {session_id} did not confirm the revocation in {wait:g} s")

    # sandbox_stop
    def stop(self, session_id: str) -> dict:
        self._dir(session_id)
        live = self.live.get(session_id)
        if live is None or live.state not in LIVE:
            return {"id": session_id, "status": "not running"}
        with live.lock:
            live.state = "stopping"
        live.send({"type": "stop"})

        def kill_later() -> None:
            try:
                live.process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                live.process.kill()

        threading.Thread(target=kill_later, daemon=True).start()
        return {"id": session_id, "status": "stopping"}
