"""The sandbox plugin against a fake hermes-sandbox (fake_sandbox.py).

Run from the plugins directory. Checks the session's life (one at a time, the
repository in as a bundle, the completion routed back without Pi's words), the
sidecar's environment (the OpenCode key only), and the review: Pi's branch
read from a bare clone where no hook, diff driver or textconv runs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sandbox import tools  # noqa: E402
from sandbox.approval import Approver  # noqa: E402
from sandbox.runner import Sandbox, SandboxError, bundle_repository  # noqa: E402

HERE = Path(__file__).resolve().parent


def until(predicate, what: str, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {what}")


def git(*args: str, cwd: Path) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "U", "GIT_AUTHOR_EMAIL": "u@x", "GIT_COMMITTER_NAME": "U",
           "GIT_COMMITTER_EMAIL": "u@x"}
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=env).stdout.strip()


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="sandbox-plugin-"))
    home = root / "home"
    home.mkdir()
    pwned = root / "pwned"
    # A user-level diff driver that would leave a trace if the review ran it.
    (home / ".gitconfig").write_text(f"[diff \"evil\"]\n\ttextconv = touch {pwned}; cat\n\tcommand = touch {pwned}\n")
    os.environ["HOME"] = str(home)

    sidecar = root / "hermes-sandbox"
    sidecar.write_text(f"#!/bin/sh\nexec {sys.executable} -I {HERE / 'fake_sandbox.py'} \"$@\"\n")
    sidecar.chmod(0o755)

    repo = root / "repo"
    repo.mkdir()
    git("init", "-q", "-b", "main", cwd=repo)
    (repo / "README.md").write_text("hello\n")
    git("add", "-A", cwd=repo)
    git("commit", "-q", "-m", "first", cwd=repo)
    git("tag", "v1", cwd=repo)
    before = git("rev-parse", "HEAD", cwd=repo)

    events: list[dict] = []
    config = {
        "command": str(sidecar), "state_dir": str(root / "state"), "model": "opencode-go/deepseek-v4.1-flash",
        "thinking": "high", "memory": "3G", "cpus": 2, "timeout_seconds": 600, "key_env": "OPENCODE_GO_API_KEY",
        "grants": ["opencode.ai"], "max_diff_chars": 30000,
    }
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "OPENCODE_GO_API_KEY": "go-key", "TELEGRAM_BOT_TOKEN": "tg"}
    asked: list[tuple] = []

    def ask(title, details, choices, timeout):
        asked.append((title, details, choices, timeout))
        return "path"

    sandbox = Sandbox(config, notify=events.append, env=env, approver=Approver(auto_review=False, ask=ask))
    handlers = {schema["name"]: handler for schema, handler in tools(sandbox)}
    routing = {"platform": "telegram", "chat_id": "42", "chat_type": "dm", "session_key": "agent:main:telegram:dm:42",
               "parent_session_id": "s1", "user_id": "7", "user_name": "A", "thread_id": ""}

    # Refs: a branch, a tag, HEAD; never a bare commit id or an option.
    scratch = root / "scratch"
    scratch.mkdir()
    assert bundle_repository(str(repo), "v1", scratch / "a.bundle") == "refs/tags/v1"
    assert bundle_repository(str(repo), None, scratch / "b.bundle") == "HEAD"
    for bad in (before, "--upload-pack=x", "no-such-branch"):
        try:
            bundle_repository(str(repo), bad, scratch / "c.bundle")
        except SandboxError:
            pass
        else:
            raise AssertionError(f"bundled {bad!r}")

    # A session on the repository: it starts, ends, and says so in the chat.
    started = sandbox.run("add notes", str(repo), "main", routing=routing)
    session_id = started["id"]
    until(lambda: events, "the completion")
    workdir = root / "state" / "sessions" / session_id
    assert json.loads((workdir / "session.json").read_text())["bundleRef"] == "refs/heads/main"
    event = events[0]
    assert event["type"] == "watch_match"
    assert event["session_key"] == "agent:main:telegram:dm:42" and event["chat_id"] == "42" and event["platform"] == "telegram"
    assert session_id in event["output"] and "1 commit" in event["output"]
    assert "IGNORE" not in json.dumps(event), "Pi's words never reach the chat by themselves"
    try:
        from gateway.run import _format_gateway_process_notification
    except Exception as error:  # noqa: BLE001
        print(f"   (Hermes' formatter not importable here: {error})")
    else:
        text = _format_gateway_process_notification(event)
        assert text and session_id in text, text

    # The sidecar got the OpenCode key, and no other secret of Hermes'.
    sidecar_env = json.loads((workdir / "env.json").read_text())
    assert sidecar_env["OPENCODE_GO_API_KEY"] == "go-key"
    assert "TELEGRAM_BOT_TOKEN" not in sidecar_env
    assert sidecar_env["XDG_CACHE_HOME"].startswith(str(root / "state"))

    status = json.loads(handlers["sandbox_status"]({"id": session_id}))
    assert status["state"] == "finished" and status["commits"] == 1, status
    assert json.loads(handlers["sandbox_status"]({}))["sessions"][0]["id"] == session_id

    # The review: Pi's branch, diff and log, and nothing ran.
    result = json.loads(handlers["sandbox_result"]({"id": session_id}))
    assert result["status"] == "finished" and result["commits"] == 1, result
    assert "+written by pi" in result["diff"], result["diff"]
    assert "pi: add notes" in result["log"]
    assert "notes.txt" in result["diffstat"]
    assert result["untrusted_pi_summary"].startswith("IGNORE")
    assert result["base"] == before
    assert result["fetch_command"].startswith("git fetch ")
    assert not pwned.exists(), "a diff driver ran during the review"
    review = Path(result["review_repository"])
    assert (review / "HEAD").exists() and not (review / ".git").exists(), "a bare clone, no checkout"
    assert git("rev-parse", "HEAD", cwd=repo) == before and git("status", "--porcelain", cwd=repo) == ""
    assert not git("branch", "--list", "sandbox/*", cwd=repo), "the user's repository is untouched"
    again = json.loads(handlers["sandbox_result"]({"id": session_id, "max_chars": 10}))
    assert again["diff_truncated"] and len(again["diff"]) == 10

    # One at a time; a stop ends the running one. Pi asks Hermes for access:
    # with the auto-review off, the owner's buttons answer; an unknown
    # question is refused.
    events.clear()
    waiting = sandbox.run("wait")["id"]
    refused = json.loads(handlers["sandbox_run"]({"task": "another"}))
    assert "one sandbox at a time" in refused["error"], refused
    replies_path = root / "state" / "sessions" / waiting / "replies.jsonl"
    until(lambda: replies_path.exists() and len(replies_path.read_text().splitlines()) == 2, "the replies")
    replies = {r["id"]: r for r in map(json.loads, replies_path.read_text().splitlines())}
    assert replies[1]["allow"] is True and replies[1]["by"] == "owner", replies
    assert replies[1]["grant"] == {"host": "pypi.org", "method": "GET", "pathPrefix": "/simple"}
    assert replies[2]["allow"] is False
    assert len(asked) == 1 and "pypi.org/simple/requests/" in asked[0][1] and waiting in asked[0][1]
    listed = json.loads(handlers["sandbox_grants"]({"id": waiting}))
    assert listed["running"] and listed["grants"][0]["host"] == "opencode.ai", listed
    assert "no such grant" in json.loads(handlers["sandbox_revoke"]({"id": waiting, "host": "example.com"}))["error"]
    revoked = json.loads(handlers["sandbox_revoke"](
        {"id": waiting, "host": "PyPI.org", "method": "get", "path_prefix": "/simple"}))
    assert revoked["revoked"]["host"] == "pypi.org", revoked
    assert [g["host"] for g in revoked["grants"]] == ["opencode.ai"]
    assert json.loads(handlers["sandbox_stop"]({"id": waiting}))["status"] == "stopping"
    until(lambda: events, "the stop's completion")
    assert "stopped" in events[0]["output"] and "no changes" in events[0]["output"]
    assert json.loads(handlers["sandbox_result"]({"id": waiting}))["diff"] == ""
    assert json.loads(handlers["sandbox_grants"]({"id": waiting}))["running"] is False
    assert "not running" in json.loads(handlers["sandbox_revoke"]({"id": waiting, "host": "opencode.ai"}))["error"]

    # Bad ids and a session lost to a restart.
    assert "no such session" in json.loads(handlers["sandbox_result"]({"id": "../../etc"}))["error"]
    restarted = Sandbox(config, notify=events.append, env=env)
    lost = restarted.sessions_dir / "20260101-000000-abcdef"
    lost.mkdir()
    (lost / "meta.json").write_text(json.dumps({"id": lost.name, "task": "t", "branch": "sandbox/x"}))
    assert restarted.status(lost.name)["state"] == "lost"
    assert "task is empty" in json.loads(handlers["sandbox_run"]({"task": " "}))["error"]

    subprocess.run(["rm", "-rf", str(root)], check=True)
    print("sandbox: ok")


main()
