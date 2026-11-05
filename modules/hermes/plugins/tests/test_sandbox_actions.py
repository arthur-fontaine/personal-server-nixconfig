"""The broker's typed actions (sandbox/actions.py) with a fake guard and a fake
owner_approval: what each asks, what the review may clear, and what is done
here once allowed (a grant, a folder, a push, an answer, a command).

Run from the plugins directory.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sandbox.actions import Actions, check, Invalid, shell_env, strip_credentials  # noqa: E402
from sandbox.approval import Approver  # noqa: E402
from sandbox.runner import SAFE_GIT, SAFE_GIT_ENV, _git  # noqa: E402

SID = "20260101-000000-abcdef"
LAUNCH = {"messages": ["Mets à jour le README et pousse la branche"], "turn_from_user": True}


def verdict(run: bool, risk: str = "low", reason: str = "fine"):
    return types.SimpleNamespace(run=run, risk=risk, reason=reason)


class Owner:
    """owner_approval.ask, answering from a list and keeping each card."""

    def __init__(self, *answers: str) -> None:
        self.answers = list(answers)
        self.cards: list = []

    def __call__(self, title, details, choices, timeout):
        self.cards.append((title, details, choices))
        return self.answers.pop(0)


class Guard:
    def __init__(self, *verdicts) -> None:
        self.verdicts = list(verdicts)
        self.calls: list = []

    def __call__(self, context, tool, args, actions):
        self.calls.append((context, tool, args, actions))
        return self.verdicts.pop(0)


def git(*args: str, cwd: Path) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@x", "GIT_CONFIG_GLOBAL": "/dev/null"}
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=env).stdout.strip()


def make(root: Path, guard: Guard | None, owner: Owner, env: dict | None = None, **kwargs) -> Actions:
    approver = Approver(auto_review=guard is not None, timeout=60, ask=owner, review=guard or Guard())
    return Actions(
        approver, state_dir=root / "state", sessions_dir=root / "state" / "sessions",
        safe_git=lambda args, cwd=None: _git(SAFE_GIT + args, cwd=cwd, env=SAFE_GIT_ENV),
        env=env if env is not None else {"PATH": os.environ["PATH"], "HOME": str(root)},
        home=str(root), **kwargs,
    )


def session(alive: bool = True, repo: str | None = None) -> dict:
    return {"id": SID, "task": "Update the README", "launch": LAUNCH, "repo": repo, "alive": lambda: alive}


def action(name: str, **args) -> dict:
    return {"kind": "action", "session": SID, "action": name, "args": args}


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="sandbox-actions-")).resolve()
    try:
        run(root)
    finally:
        subprocess.run(["chmod", "-R", "u+rwx", str(root)], check=False)
        subprocess.run(["rm", "-rf", str(root)], check=False)
    print("sandbox actions: ok")


def run(root: Path) -> None:
    # The schema again on this side: unknown fields and actions refused.
    for bad in [("shell", {"command": "ls", "justification": "x"}), ("nope", {}), ("git_push", {"branch": "main"}),
                ("ask_user", {"question": "q", "choices": ["a"]}), ("shell", {})]:
        try:
            check(*bad)
        except Invalid:
            continue
        raise AssertionError(f"accepted {bad}")
    refused = make(root, None, Owner()).handle(session(), action("shell", command="id", why="please"))
    assert refused["status"] == "error" and refused["by"] == "policy", refused

    # request_host: cleared at low risk, a grant; otherwise the owner.
    guard, owner = Guard(verdict(True, "low"), verdict(True, "medium", "medium risk")), Owner("grant")
    actions = make(root, guard, owner)
    reply = actions.handle(session(), action("request_host", host="pypi.org", method="GET", pathPrefix="/simple"))
    assert reply["status"] == "allowed" and reply["by"] == "guard", reply
    assert reply["grant"] == {"host": "pypi.org", "method": "GET", "pathPrefix": "/simple"}
    context, tool, args, history = guard.calls[0]
    assert context == LAUNCH and tool == "sandbox_request_host"
    assert args == {"session": SID, "host": "pypi.org", "method": "GET", "pathPrefix": "/simple"}, args
    assert not owner.cards
    reply = actions.handle(session(), action("request_host", host="files.example.com"))
    assert reply["by"] == "owner" and reply["grant"] == {"host": "files.example.com", "method": None, "pathPrefix": None}
    assert "Auto-review: medium risk." in owner.cards[0][1] and "files.example.com" in owner.cards[0][1]

    # shell: never auto-allowed, even when the review says run.
    guard, owner = Guard(verdict(True, "low", "looks harmless")), Owner("run")
    secret = "sk-ant-api03-" + "q" * 40
    env = {"PATH": os.environ["PATH"], "HOME": str(root), "OPENCODE_GO_API_KEY": "go-secret-value",
           "TELEGRAM_BOT_TOKEN": "123:tg-secret"}
    actions = make(root, guard, owner, env=env)
    reply = actions.handle(session(), action("shell", command=f"env; echo {secret}; pwd; printf '%5000s' x"))
    assert [c[1] for c in guard.calls] == ["sandbox_shell"], "reviewed, for the card"
    assert len(owner.cards) == 1, "the owner is asked anyway"
    title, details, choices = owner.cards[0]
    assert [c[0] for c in choices] == ["run", "deny"]
    assert "Auto-review: looks harmless." in details and "printf" in details
    assert reply["status"] == "allowed" and reply["by"] == "owner", reply
    output = reply["result"]["output"]
    assert reply["result"]["exit_code"] == 0
    assert "go-secret-value" not in output and "tg-secret" not in output, "no secret of Hermes' environment"
    assert secret not in output, "the output is redacted"
    assert str(root / "state" / "shell") in output, "a temporary folder"
    assert len(output) <= 4096
    assert not list((root / "state" / "shell").iterdir()), "the temporary folder is gone"
    assert set(shell_env(env, "/h", "/t")) == {"PATH", "HOME", "TMPDIR", "LANG", "TERM", "GIT_TERMINAL_PROMPT"}

    # shell with the auto-review off; a cwd; a timeout; a refusal; a dead session.
    owner = Owner("run", "run", "deny", "timeout", "run")
    actions = make(root, None, owner, shell_timeout=1)
    (root / "work").mkdir()
    reply = actions.handle(session(), action("shell", command="pwd; exit 3", cwd=str(root / "work")))
    assert reply["result"]["exit_code"] == 3 and reply["result"]["output"].strip() == str(root / "work"), reply
    assert f"In: {root / 'work'}" in owner.cards[0][1]
    reply = actions.handle(session(), action("shell", command="sleep 30"))
    assert reply["result"]["timed_out"] and reply["result"]["exit_code"] is None, reply
    assert actions.handle(session(), action("shell", command="id"))["status"] == "denied"
    assert actions.handle(session(), action("shell", command="id"))["status"] == "timeout"
    marker = root / "ran"
    reply = actions.handle(session(alive=False), action("shell", command=f"touch {marker}"))
    assert reply["status"] == "error" and not marker.exists(), "nothing runs for a session that ended"
    missing = actions.handle(session(), action("shell", command="id", cwd="/nonexistent"))
    assert missing["status"] == "error" and len(owner.cards) == 5, "no question for a cwd that is not there"

    # request_folder: resolved here, shown absolute, the same error for missing or forbidden.
    (root / "notes").mkdir()
    (root / "link").symlink_to(root / "notes")
    (root / "closed").mkdir(mode=0o000)
    owner = Owner("copy", "deny")
    actions = make(root, None, owner)
    reply = actions.handle(session(), action("request_folder", path="~/link"))
    assert reply["status"] == "allowed" and reply["folder"] == {"path": str(root / "notes")}, reply
    assert f"Folder: {root / 'notes'}" in owner.cards[0][1] and "(asked as ~/link)" in owner.cards[0][1]
    assert actions.handle(session(), action("request_folder", path=str(root / "notes")))["status"] == "denied"
    for path in ["/nonexistent", str(root / "closed"), "relative/path", "~other/x"]:
        reply = actions.handle(session(), action("request_folder", path=path))
        assert reply["status"] == "error" and reply["result"] == {"error": "not a folder Hermes can read"}, (path, reply)
    assert len(owner.cards) == 2
    guard = Guard(verdict(True, "medium"))
    reply = make(root, guard, Owner()).handle(session(), action("request_folder", path=str(root / "notes")))
    assert reply["by"] == "guard" and guard.calls[0][2] == {"session": SID, "path": str(root / "notes")}

    # git_push: the session's branch only, from the review clone, no hooks, no force.
    origin = root / "origin.git"
    git("init", "-q", "--bare", str(origin), cwd=root)
    repo = root / "repo"
    git("init", "-q", "-b", "main", str(repo), cwd=root)
    (repo / "README").write_text("v1\n")
    git("add", "-A", cwd=repo)
    git("commit", "-q", "-m", "v1", cwd=repo)
    base = git("rev-parse", "HEAD", cwd=repo)
    git("remote", "add", "origin", f"file://{origin}", cwd=repo)
    git("push", "-q", "origin", "main", cwd=repo)
    guest = root / "guest"
    git("clone", "-q", str(repo), str(guest), cwd=root)
    branch = f"sandbox/{SID}"
    git("checkout", "-q", "-b", branch, cwd=guest)
    (guest / "README").write_text("v2\n")
    git("commit", "-qam", "pi: v2", cwd=guest)
    workdir = root / "state" / "sessions" / SID
    workdir.mkdir(parents=True)
    git("bundle", "create", "-q", str(workdir / "push-1.bundle"), branch, cwd=guest)
    # A hook in the review clone would run on push without core.hooksPath.
    owner = Owner("push", "deny")
    actions = make(root, None, owner)
    for other in ["sandbox/20260101-000000-ffffff", f"sandbox/{SID}x", "sandbox/other"]:
        reply = actions.handle(session(repo=str(repo)), {**action("git_push", branch=other), "bundle": "push-1.bundle"})
        assert reply["status"] == "denied" and reply["by"] == "policy", (other, reply)
    assert not owner.cards
    bad_bundle = actions.handle(session(repo=str(repo)), {**action("git_push", branch=branch), "bundle": "../x"})
    assert bad_bundle["status"] == "error"
    review = workdir / "review.git"
    actions.fetch_review(review, workdir / "push-1.bundle", branch)
    hook = review / "hooks" / "pre-push"
    hook.parent.mkdir(exist_ok=True)
    pwned = root / "hook-ran"
    hook.write_text(f"#!/bin/sh\ntouch {pwned}\n")
    hook.chmod(0o755)
    message = {**action("git_push", branch=branch), "bundle": "push-1.bundle", "base": base}
    reply = actions.handle(session(repo=str(repo)), message)
    assert reply["status"] == "allowed" and reply["by"] == "owner", reply
    assert git("rev-parse", branch, cwd=origin) == git("rev-parse", "HEAD", cwd=guest)
    assert not pwned.exists(), "no hook ran"
    card = owner.cards[0][1]
    assert f"Remote: file://{origin}" in card and "1 commit(s)" in card and branch in card, card
    # A rewritten branch is not forced over the pushed one.
    git("commit", "-q", "--amend", "-m", "pi: rewritten", cwd=guest)
    git("bundle", "create", "-q", str(workdir / "push-2.bundle"), branch, cwd=guest)
    owner.answers = ["push"]
    reply = actions.handle(session(repo=str(repo)), {**message, "bundle": "push-2.bundle"})
    assert reply["status"] == "error" and reply["result"] == {"error": "the push failed"}, reply
    assert git("rev-parse", branch, cwd=origin) != git("rev-parse", "HEAD", cwd=guest)
    assert not (repo / ".git" / "refs" / "heads" / "sandbox").exists(), "the user's checkout is untouched"
    # The reviewer sees the remote without credentials, and the push's facts.
    guard = Guard(verdict(False, "high", "pushes are high risk"))
    owner = Owner("deny")
    git("remote", "set-url", "origin", "https://user:hunter2@example.com/r.git", cwd=repo)
    reply = make(root, guard, owner).handle(session(repo=str(repo)), {**message, "bundle": "push-2.bundle"})
    assert reply["status"] == "denied"
    assert guard.calls[0][1] == "sandbox_git_push"
    assert guard.calls[0][2] == {"session": SID, "branch": branch, "remote": "https://example.com/r.git", "commits": 1}
    assert "hunter2" not in json.dumps(owner.cards)
    assert strip_credentials("git@github.com:a/b.git") == "git@github.com:a/b.git"
    no_repo = make(root, None, Owner()).handle(session(), {**message})
    assert no_repo["status"] == "error" and no_repo["result"] == {"error": "the session has no repository"}

    # ask_user: the owner's choice, Pi's words marked as such; never reviewed.
    guard, owner = Guard(), Owner("c1", "deny", "timeout")
    actions = make(root, guard, owner)
    reply = actions.handle(session(), action("ask_user", question="Keep the old API?", choices=["yes", "no"]))
    assert reply == {"status": "allowed", "by": "owner", "reason": "answered", "outcome": "allowed",
                     "result": {"answer": "no"}}, reply
    title, details, choices = owner.cards[0]
    assert "its words, not Hermes'" in details and "Keep the old API?" in details
    assert [c[0] for c in choices] == ["c0", "c1", "deny"]
    assert not guard.calls
    assert actions.handle(session(), action("ask_user", question="q", choices=["a", "b"]))["status"] == "denied"
    assert actions.handle(session(), action("ask_user", question="q", choices=["a", "b"]))["status"] == "timeout"
    owner.answers = ["c0"] * 20
    statuses = [actions.handle(session(), action("ask_user", question=f"q{n}", choices=["a", "b"]))["status"]
                for n in range(10)]
    assert statuses.count("denied") == 3, "a bounded number of questions per session"


if __name__ == "__main__":
    main()
