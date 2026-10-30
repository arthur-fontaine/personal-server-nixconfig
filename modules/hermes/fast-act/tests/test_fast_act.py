"""fast_act against a fake System One server on loopback and a fake Cua Driver."""

from __future__ import annotations

import asyncio
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fast_act import candidates as cands  # noqa: E402
from fast_act import decision  # noqa: E402
from fast_act import server  # noqa: E402

REQUESTS: list[dict] = []
ANSWERS: list[dict] = []


class SystemOne(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        REQUESTS.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        answer = ANSWERS.pop(0)
        if "status" in answer:
            self.send_response(answer["status"])
            self.end_headers()
            return
        answers = {}
        for name, question in body["questions"].items():
            # A System One model answers every question; those the test leaves
            # out get the first option.
            choose = answer.get(name, lambda criteria: next(iter(criteria)))
            choice = choose(question["criteria"])
            answers[name] = {"type": "choice", "choice": choice, "confidence": 0.9, "probabilities": {choice: 0.9}}
        data = {"model": "fake-elephant", "answers": answers}
        payload = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args) -> None:
        pass


def pick(word: str):
    return lambda criteria: next(k for k, v in criteria.items() if word in v)


def op(name: str):
    return lambda criteria: name


CLICK_THIERRY = {"operation": op("click"), "click_target": pick("Thierry"), "type_target": pick("Message"), "text": op("t0")}
DONE = {"operation": op("done")}


class FakeDriver:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.page = "inbox"

    async def call(self, name: str, arguments: dict) -> dict:
        self.calls.append((name, arguments))
        if name == "list_windows":
            return {"windows": [{"window_id": 7, "is_on_screen": True, "bounds": {"width": 800, "height": 600}}]}
        if name == "get_browser_state" and "snapshot_format" not in arguments:
            return {"target_id": "t1", "tabs": [{"tab_id": "a"}, {"tab_id": "b", "active": True}]}
        if name == "get_browser_state":
            refs = [{"ref": f"p1:{i}", "role": "link", "name": f"Story {i}"} for i in range(40)]
            refs.append({"ref": "p1:90", "role": "link", "name": "Thierry Martin"})
            refs.append({"ref": "p1:91", "role": "button", "name": "Send"})
            refs.append({"ref": "p1:92", "role": "textbox", "name": "Message", "actions": ["click", "type"]})
            return {"url": "https://www.instagram.com/direct/", "title": self.page, "outline": "Inbox", "refs": refs}
        if name == "browser_click" and arguments["ref"] == "p1:90":
            self.page = "thierry"
        return {"status": "ok"}


def config(port: int) -> decision.Config:
    return decision.Config.from_env({
        "OPENJEV_BASE_URL": f"http://127.0.0.1:{port}",
        "OPENJEV_MODEL": "decision-models/baseten-elephant-9b-latest",
        "OPENJEV_AUTH_SCHEME": "Api-Key",
        "OPENJEV_API_KEY": "k",
    })


def test_config() -> None:
    c = decision.Config.from_env({"OPENJEV_BASE_URL": "https://inference.baseten.co/v1/systemone/"})
    assert c.url == "https://inference.baseten.co/v1/systemone" and c.model == "openjev"
    assert c.auth_scheme == "Bearer" and c.timeout_s == 10
    assert decision.Config.from_env({"OPENJEV_BASE_URL": "https://api.typesafe.ai"}).url.endswith("/v1/systemone")
    for bad in ["ftp://x", "https://u:p@x", "https://x/?k=1", "http://example.com"]:
        try:
            decision.Config.from_env({"OPENJEV_BASE_URL": bad, "OPENJEV_API_KEY": "k"})
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad}")


def test_candidates() -> None:
    snapshot = asyncio.run(FakeDriver().call("get_browser_state", {"snapshot_format": "semantic_v2"}))
    snapshot.update(target_id="t1", tab_id="b")
    questions = cands.build(snapshot, goal="open the conversation with Thierry")
    criteria = questions.criteria()
    clicks = criteria["click_target"][1]
    assert next(iter(clicks.values())) == 'the link "Thierry Martin"', list(clicks.values())[:3]
    assert len(clicks) == cands.MAX_TARGETS
    assert not any("Send" in v for v in clicks.values())  # Send stays out unless allowed
    assert set(criteria["operation"][1]) == {"click", "type", "done", "reobserve", "abstain"}
    assert "text" not in criteria
    risky = cands.build(snapshot, goal="send it", texts=["Thierry", "Salut"], allow_risky=True)
    criteria = risky.criteria()
    assert any("Send" in v for v in criteria["click_target"][1].values())
    assert criteria["text"][1] == {"t0": '"Thierry"', "t1": '"Salut"'}
    field = next(k for k, v in criteria["type_target"][1].items() if "Message" in v)
    tool, arguments = risky.type(field, "Salut")
    assert tool == "browser_type" and arguments == {"target_id": "t1", "tab_id": "b", "ref": "p1:92", "text": "Salut", "replace": True}
    # A page with nothing to type into does not offer typing.
    plain = cands.build({"target_id": "t", "tab_id": "a", "refs": [{"ref": "x", "role": "link", "name": "Home"}]}, goal="g")
    assert set(plain.criteria()) == {"operation", "click_target"} and "type" not in plain.criteria()["operation"][1]


def test_loop(port: int) -> None:
    REQUESTS.clear()
    ANSWERS[:] = [CLICK_THIERRY, DONE]
    driver = FakeDriver()
    report = asyncio.run(server.run(
        "open the conversation with Thierry", texts=[], url="https://www.instagram.com/direct/",
        allow_risky=False, max_steps=5, driver=driver, pid=1, config=config(port),
    ))
    assert driver.page == "thierry", report
    assert ("browser_navigate", {"target_id": "t1", "tab_id": "b", "url": "https://www.instagram.com/direct/"}) in driver.calls
    assert "Thierry Martin" in report and "goal is already reached" in report, report
    first = REQUESTS[0]
    assert first["path"] == "/v1/systemone" and first["auth"] == "Api-Key k"
    assert first["body"]["model"] == "decision-models/baseten-elephant-9b-latest"
    assert set(first["body"]["questions"]) == {"operation", "click_target", "type_target"}
    assert first["body"]["questions"]["operation"]["type"] == "choice"
    # The model sees IDs and descriptions only, never tools or arguments.
    assert "browser_click" not in json.dumps(first["body"])
    assert REQUESTS[1]["body"]["state"]["history"][0]["action"] == 'Click the link "Thierry Martin"'

    # Typing the right one of Hermes' texts, then stopping when a field needs
    # a text Hermes did not give.
    REQUESTS.clear()
    ANSWERS[:] = [{"operation": op("type"), "type_target": pick("Message"), "text": op("t1"), "click_target": pick("Thierry")}, DONE]
    driver = FakeDriver()
    report = asyncio.run(server.run(
        "send Thierry the message", texts=["Thierry", "Salut !"], url=None, allow_risky=True,
        max_steps=5, driver=driver, pid=1, config=config(port),
    ))
    assert ("browser_type", {"target_id": "t1", "tab_id": "b", "ref": "p1:92", "text": "Salut !", "replace": True}) in driver.calls, report
    ANSWERS[:] = [{"operation": op("type"), "type_target": pick("Message"), "click_target": pick("Thierry")}]
    report = asyncio.run(server.run(
        "send Thierry the message", texts=[], url=None, allow_risky=False,
        max_steps=5, driver=FakeDriver(), pid=1, config=config(port),
    ))
    assert "needs a text" in report, report


def test_model_errors(port: int) -> None:
    for answer, expected in [
        ({"status": 401}, "HTTP 401"),
        ({"operation": op("not-offered")}, "not offered"),
    ]:
        ANSWERS[:] = [answer]
        report = asyncio.run(server.run(
            "anything", texts=[], url=None, allow_risky=False, max_steps=3,
            driver=FakeDriver(), pid=1, config=config(port),
        ))
        assert "stopped" in report and expected in report, report
    try:
        decision.choose(decision.Config.from_env({"OPENJEV_BASE_URL": "http://127.0.0.1:9"}),
                        instructions="x", state={}, criteria={"a": "b"})
    except decision.DecisionError as error:
        assert "unreachable" in str(error)
    else:
        raise AssertionError("an unreachable model did not fail")


def test_over_mcp(port: int, tmp: Path) -> None:
    """The tool itself, its driver a real MCP server over stdio (fake_driver.py)."""
    import os

    driver = tmp / "cua-driver"
    driver.write_text(f"#!/bin/sh\nexec {sys.executable} -I {Path(__file__).with_name('fake_driver.py')}\n")
    driver.chmod(0o755)
    os.environ.update({
        "CUA_DRIVER_BIN": str(driver),
        "OPENJEV_BASE_URL": f"http://127.0.0.1:{port}",
        "OPENJEV_MODEL": "m",
    })
    server.chrome_pid = lambda profile: 1  # no Chrome here
    os.environ["FAST_ACT_CHROME_PROFILE"] = str(tmp / "profile")
    ANSWERS[:] = [{"operation": op("click"), "click_target": pick("Thierry")}, DONE]
    report = asyncio.run(server.browser_fast_act("open the conversation with Thierry"))
    assert 'Click the link "Thierry Martin"' in report and "goal is already reached" in report, report


def main() -> None:
    httpd = HTTPServer(("127.0.0.1", 0), SystemOne)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    port = httpd.server_address[1]
    test_config()
    test_candidates()
    test_loop(port)
    test_model_errors(port)
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        test_over_mcp(port, Path(tmp))
    assert server.server.name == "fast-act"
    httpd.shutdown()
    print("fast_act: ok")


if __name__ == "__main__":
    main()
