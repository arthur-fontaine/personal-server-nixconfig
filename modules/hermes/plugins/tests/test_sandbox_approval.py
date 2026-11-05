"""The sandbox's network questions (sandbox/approval.py) with a fake guard and
a fake owner_approval: the auto-review first, against the user's launching
messages only, then the owner's buttons.

Run from the plugins directory.
"""

from __future__ import annotations

import sys
import threading
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sandbox import approval  # noqa: E402
from sandbox.approval import Approver, grant_prefix  # noqa: E402

SESSION = {"id": "20260101-000000-abcdef", "task": "Fix the requests import\nin app.py",
           "launch": {"messages": ["Fixe l'import de requests"], "turn_from_user": True}}
QUESTION = {"kind": "network", "host": "pypi.org", "method": "GET", "path": "/simple/requests/", "scheme": "https",
            "ambiguous": False}


class Verdict(types.SimpleNamespace):
    pass


def main() -> None:
    assert grant_prefix("/simple/requests/") == "/simple"
    assert grant_prefix("/repos/a/b/pulls") == "/repos/a/b"
    assert grant_prefix("/x") == "/x" and grant_prefix("/") == "/"

    # The auto-review clears it at low risk: allowed, with a method+path grant.
    reviewed: list = []

    def review(verdict):
        def call(context, tool, args, actions):
            reviewed.append((context, tool, args, actions))
            return verdict
        return call

    def never_ask(*args):
        raise AssertionError("the owner was asked")

    a = Approver(auto_review=True, ask=never_ask, review=review(Verdict(run=True, reason="low risk, high", risk="low")))
    answer = a.decide(SESSION, QUESTION)
    assert answer == {"allow": True, "by": "guard", "reason": "low risk, high",
                      "grant": {"host": "pypi.org", "method": "GET", "pathPrefix": "/simple"}}, answer
    context, tool, args, actions = reviewed[-1]
    assert context == SESSION["launch"], "the user's launching messages, nothing else"
    assert tool == "sandbox_network"
    assert args == {"session": SESSION["id"], "method": "GET", "host": "pypi.org", "path": "/simple/requests/"}
    assert actions[0].startswith("sandbox_run (session") and "\n" not in actions[0]

    # Cleared at medium risk: this request only, no grant.
    a = Approver(auto_review=True, ask=never_ask, review=review(Verdict(run=True, reason="medium", risk="medium")))
    assert "grant" not in a.decide(SESSION, QUESTION)

    # Not cleared: the owner decides, told what the review said.
    asked: list = []
    answers = iter(["once", "path", "host", "deny", "timeout", "unavailable"])

    def ask(title, details, choices, timeout):
        asked.append((title, details, choices, timeout))
        return next(answers)

    a = Approver(auto_review=True, timeout=90, ask=ask,
                 review=review(Verdict(run=False, reason="high risk, unknown authorization", risk="high")))
    outcomes = [a.decide(SESSION, QUESTION) for _ in range(6)]
    assert [o["allow"] for o in outcomes] == [True, True, True, False, False, False]
    assert [o["by"] for o in outcomes] == ["owner", "owner", "owner", "owner", "timeout", "unavailable"]
    assert "grant" not in outcomes[0]
    assert outcomes[1]["grant"] == {"host": "pypi.org", "method": "GET", "pathPrefix": "/simple"}
    assert outcomes[2]["grant"] == {"host": "pypi.org"}
    title, details, choices, timeout = asked[0]
    assert timeout == 90
    assert [c[0] for c in choices] == ["once", "path", "host", "deny"]
    assert SESSION["id"] in details and "GET https://pypi.org/simple/requests/" in details
    assert "Fix the requests import?in app.py" in details, "one line, control characters replaced"
    assert "high risk, unknown authorization" in details

    # Auto-review off: straight to the owner, no review at all.
    reviewed.clear()
    a = Approver(auto_review=False, ask=lambda *a: "once", review=review(Verdict(run=True, reason="x", risk="low")))
    assert a.decide(SESSION, QUESTION)["by"] == "owner" and not reviewed
    # On, but guard not loaded: the owner too.
    a = Approver(auto_review=True, ask=lambda *a: "once", review=lambda *a: None)
    assert a.decide(SESSION, QUESTION)["by"] == "owner"
    # A review that raises is no review.
    def boom(*a):
        raise RuntimeError("model down")
    assert Approver(auto_review=True, ask=lambda *a: "deny", review=boom).decide(SESSION, QUESTION)["by"] == "owner"

    # An ambiguous path is never auto-reviewed, and gets no path grant.
    asked.clear()
    reviewed.clear()
    a = Approver(auto_review=True, ask=ask, review=review(Verdict(run=True, reason="x", risk="low")))
    answers = iter(["path"])
    sneaky = {**QUESTION, "path": "/simple%2F..%2Fadmin", "ambiguous": True}
    assert a.decide(SESSION, sneaky)["allow"] is False, "no path choice was offered"
    assert not reviewed and [c[0] for c in asked[0][2]] == ["once", "host", "deny"]

    # The guest's text, shown escaped and cut.
    asked.clear()
    answers = iter(["deny"])
    long = {**QUESTION, "path": "/" + "a" * 2000}
    Approver(auto_review=False, ask=ask).decide(SESSION, long)
    assert len(asked[0][1]) < 1200 and "…" in asked[0][1]

    # Malformed: refused without asking.
    for bad in ({**QUESTION, "host": "a b"}, {**QUESTION, "method": "get me"}, {**QUESTION, "path": "x"}):
        assert Approver(auto_review=False, ask=never_ask).decide(SESSION, bad)["by"] == "policy"

    # At most a few open questions per session; the others are refused.
    release = threading.Event()

    def slow(*args):
        release.wait(5)
        return "once"

    a = Approver(auto_review=False, ask=slow)
    results: list = []
    threads = [threading.Thread(target=lambda: results.append(a.decide(SESSION, QUESTION))) for _ in range(approval.MAX_OPEN)]
    for t in threads:
        t.start()
    deadline = time.monotonic() + 5
    while a.open.get(SESSION["id"], 0) < approval.MAX_OPEN and time.monotonic() < deadline:
        time.sleep(0.01)
    assert a.decide(SESSION, QUESTION)["by"] == "limit"
    release.set()
    for t in threads:
        t.join()
    assert all(r["allow"] for r in results) and not a.open

    # The real owner_approval and guard are found by their module names.
    calls: list = []
    fake_oa = types.ModuleType("owner_approval")
    fake_oa.ask = lambda title, details, choices, timeout=300: calls.append(timeout) or "deny"
    fake_guard = types.ModuleType("guard")
    fake_guard.GUARD = object()
    fake_guard.review_action = lambda context, tool, args, actions: Verdict(run=False, reason="r", risk="high")
    sys.modules["owner_approval"], sys.modules["guard"] = fake_oa, fake_guard
    try:
        assert Approver(auto_review=True, timeout=7).decide(SESSION, QUESTION) == {
            "allow": False, "by": "owner", "reason": "denied"}
        assert calls == [7]
    finally:
        del sys.modules["owner_approval"], sys.modules["guard"]
    assert Approver(auto_review=False).decide(SESSION, QUESTION)["by"] == "unavailable"

    print("sandbox approval: ok")


main()
