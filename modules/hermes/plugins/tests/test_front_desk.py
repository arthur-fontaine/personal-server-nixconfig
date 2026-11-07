"""front_desk in Hermes' own agent loop: the plugin loaded by Hermes' plugin
manager from a Hermes home, real AIAgents (the main chat's, a delegate_task
child's, an event's) whose model is a scripted client, as upstream tests its
tool pipeline (tests/agent/test_local_tool_batches.py at the pinned revision).
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

PLUGINS = Path(__file__).resolve().parent.parent
OWNER = "4242"
MAIN = f"agent:main:telegram:dm:{OWNER}"
CALLS = 3  # the budget under test, in tool calls

home = Path(tempfile.mkdtemp())
os.environ.update(HOME=str(home), HERMES_HOME=str(home / ".hermes"), TELEGRAM_ALLOWED_USERS=f"{OWNER},77")
hermes_home = home / ".hermes"
shutil.copytree(PLUGINS / "front_desk", hermes_home / "plugins" / "front_desk")
(hermes_home / "front_desk").mkdir()
(hermes_home / "front_desk" / "config.json").write_text(
    json.dumps({"seconds": 120, "tool_calls": CALLS, "foreground_seconds": 60}))
(hermes_home / "config.yaml").write_text(json.dumps({"plugins": {"enabled": ["front_desk"]}}))
workdir = home / "work"
workdir.mkdir()
(workdir / "notes.txt").write_text("".join(f"line {i}\n" for i in range(30)))

from hermes_cli.plugins import discover_plugins, get_plugin_manager  # noqa: E402

discover_plugins(force=True)
assert "front_desk" in get_plugin_manager()._plugins, get_plugin_manager()._plugins.keys()


def call(name, args, call_id):
    return SimpleNamespace(id=call_id, type="function",
                           function=SimpleNamespace(name=name, arguments=json.dumps(args)))


def response(calls=None, text="done"):
    return SimpleNamespace(choices=[SimpleNamespace(
        message=SimpleNamespace(content="" if calls else text, tool_calls=calls),
        finish_reason="tool_calls" if calls else "stop")], model="test/model", usage=None)


def agent(platform, session_id, *, parent=None, toolsets=("file",)):
    from run_agent import AIAgent

    with patch("agent.process_bootstrap.OpenAI"), patch("agent.model_metadata.fetch_model_metadata", return_value={}):
        a = AIAgent(model="test/model", api_key="test-key", base_url="http://127.0.0.1:1/v1",
                    enabled_toolsets=list(toolsets), quiet_mode=True, platform=platform,
                    session_id=session_id, parent_session_id=parent,
                    skip_context_files=True, skip_memory=True, max_iterations=20)
    a.client = MagicMock()
    a._cached_system_prompt = "Use the tools."
    a._use_prompt_caching = False
    a.compression_enabled = False
    a.save_trajectories = False
    return a


def run(a, session_key, steps, message="read it"):
    """One turn: the model makes each step's tool calls in turn, then answers.
    Returns the tool results in order."""
    from gateway.session_context import scoped_session_key

    a.client.chat.completions.create.side_effect = [
        response([call(name, args, f"c{i}")]) for i, (name, args) in enumerate(steps)] + [response()]
    with scoped_session_key(session_key):
        result = a.run_conversation(message)
    return [m["content"] for m in result["messages"] if m.get("role") == "tool"]


# Each call reads another line: Hermes refuses a third identical read by itself.
reads = [("read_file", {"path": str(workdir / "notes.txt"), "offset": i + 1}) for i in range(20)]


def blocked(content):
    return "Not run:" in content and "delegate_task" in content


def test_main_chat_blocks_past_the_budget():
    results = run(agent("telegram", "main-1"), MAIN, reads[:CALLS + 2])
    assert len(results) == CALLS + 2, results
    assert not any(blocked(r) for r in results[:CALLS]), results[:CALLS]
    assert all(blocked(r) for r in results[CALLS:]), results[CALLS:]
    # Dispatching and recalling stay open past the budget, and never count.
    results = run(agent("telegram", "main-2", toolsets=("file", "todo")), MAIN,
                  reads[:CALLS] + [("todo_list", {})] + reads[CALLS:CALLS + 1])
    assert not blocked(results[CALLS]), results[CALLS]
    assert blocked(results[CALLS + 1])


def test_a_new_turn_starts_a_new_budget():
    a = agent("telegram", "main-3")
    assert blocked(run(a, MAIN, reads[:CALLS + 1])[-1])
    assert not any(blocked(r) for r in run(a, MAIN, reads[:CALLS]))


def test_never_outside_the_main_chat():
    many = reads[:CALLS + 3]
    for platform, key, parent in [
        ("subagent", MAIN, "main-1"),                       # a delegate_task child of the main chat
        ("webhook", "agent:main:webhook:dm:events", None),  # an event's turn
        ("telegram", f"{MAIN}:77", None),                   # a topic of the DM: a sub-chat
        ("telegram", "agent:main:telegram:group:-100", None),
        ("telegram", "agent:main:telegram:dm:77", None),    # not the owner's DM
        ("cli", "", None),
    ]:
        results = run(agent(platform, f"other-{platform}-{len(key)}", parent=parent), key, many)
        assert not any(blocked(r) for r in results), (platform, key, results)


def test_a_child_of_the_main_chat_is_not_capped():
    """The main chat's turn delegates; its child (a real delegate_task child,
    in the background) makes more calls than the budget."""
    parent = agent("telegram", "main-4", toolsets=("file", "delegation"))
    goal = "read notes.txt many times"
    parent_script = iter([response([call("delegate_task", {"goal": goal}, "d")]), response(text="launched")])
    child_script = iter([response([call(*reads[i], f"k{i}")]) for i in range(CALLS + 2)]
                        + [response(text="child done")])
    child_results, child_done = [], []

    def create(**kwargs):
        messages = kwargs.get("messages", [])
        if not any(goal in json.dumps(m.get("content"), default=str) for m in messages if m.get("role") != "tool"):
            return next(parent_script)
        child_results[:] = [m["content"] for m in messages if m.get("role") == "tool"]
        step = next(child_script)
        if step.choices[0].message.tool_calls is None:
            child_done.append(True)
        return step

    parent.client.chat.completions.create.side_effect = create
    from gateway.session_context import scoped_session_key

    with patch("agent.process_bootstrap.OpenAI", return_value=parent.client), \
            patch("agent.model_metadata.fetch_model_metadata", return_value={}), \
            scoped_session_key(MAIN):
        result = parent.run_conversation("read it many times, in the background")
        delegated = [m["content"] for m in result["messages"] if m.get("role") == "tool"]
        assert delegated and not blocked(delegated[0]) and "dispatched" in delegated[0], delegated
        deadline = time.monotonic() + 60
        while not child_done:
            assert time.monotonic() < deadline, ("the child never finished", child_results)
            time.sleep(0.05)
    assert len(child_results) == CALLS + 2, child_results
    assert not any(blocked(r) for r in child_results), child_results


def test_a_long_foreground_command_goes_to_the_background():
    from gateway.session_context import scoped_session_key
    from hermes_cli.plugins import _dispatch_pre_tool_call_hooks, invoke_hook

    def turn(n):
        # A fresh turn of the main chat, through Hermes' own hook dispatch.
        with scoped_session_key(MAIN):
            invoke_hook("pre_llm_call", session_id="main-5", turn_id=f"t{n}", platform="telegram",
                        parent_session_id="", user_message="build it")
        return dict(session_id="main-5", turn_id=f"t{n}", task_id="t")

    cases = [({"command": "sleep 1", "timeout": 600}, True), ({"command": "cd x && nix build .#a"}, True),
             ({"command": "nx2apple build --release"}, True), ({"command": "sleep 300"}, True),
             ({"command": "sudo darwin-rebuild switch"}, True), ({"command": "pnpm install"}, True),
             ({"command": "ls"}, False), ({"command": "echo build"}, False), ({"command": "sleep 5"}, False),
             ({"command": "nix build", "background": True, "notify": True}, False),
             ({"command": "ls", "timeout": 30}, False), ({"command": "grep -r make ."}, False)]
    for n, (args, rewritten) in enumerate(cases):
        block, modified = _dispatch_pre_tool_call_hooks("terminal", args, **turn(n))
        assert block is None, (args, block)
        assert modified == ({**args, "background": True, "notify": True} if rewritten else None), (args, modified)
    # Not in a subagent: a child waits for its own builds (delegation.md).
    ids = turn(99)
    assert _dispatch_pre_tool_call_hooks("terminal", {"command": "nix build"}, session_id="child",
                                         turn_id=ids["turn_id"]) == (None, None)
    # Past the budget the command is blocked like any other, not moved.
    for _ in range(CALLS):
        _dispatch_pre_tool_call_hooks("terminal", {"command": "ls"}, **ids)
    block, _ = _dispatch_pre_tool_call_hooks("terminal", {"command": "nix build"}, **ids)
    assert blocked(block or ""), block


def test_the_rewritten_call_runs_in_the_background():
    """The real terminal tool takes the rewritten call: a background process
    that notifies, and the turn goes on at once."""
    a = agent("telegram", "main-6", toolsets=("terminal",))
    started = time.monotonic()
    results = run(a, MAIN, [("terminal", {"command": "sleep 3 && echo finished", "timeout": 600})], "build it")
    assert time.monotonic() - started < 3, "the turn waited for the command"
    data = json.loads(results[0])
    assert data.get("session_id") and data.get("notify_on_complete") is not None, data
    from tools.process_registry import process_registry

    session = process_registry.get(data["session_id"])
    deadline = time.monotonic() + 30
    while not session.exited:
        assert time.monotonic() < deadline, "the background command never finished"
        time.sleep(0.1)
    assert "finished" in session.output_buffer


def test_waiting_on_the_user_is_not_the_turn_s_time():
    import front_desk

    now = [0.0]
    desk = front_desk.FrontDesk(seconds=120, tool_calls=100, clock=lambda: now[0])
    from gateway.session_context import scoped_session_key

    with scoped_session_key(MAIN):
        desk.pre_llm_call(session_id="s", turn_id="t", platform="telegram")
    desk.on_human_input_request(request_id="r", session_id="", session_key=MAIN)
    now[0] = 600.0  # ten minutes before the user taps Approve
    assert desk.pre_tool_call("read_file", {}, session_id="s", turn_id="t") is None
    desk.on_human_input_resolved(request_id="r", session_key=MAIN)
    now[0] = 650.0
    assert desk.pre_tool_call("read_file", {}, session_id="s", turn_id="t") is None
    now[0] = 730.0
    assert desk.pre_tool_call("read_file", {}, session_id="s", turn_id="t")["action"] == "block"


if __name__ == "__main__":
    sys.path.insert(0, str(PLUGINS))
    failures = 0
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print("ok", name)
            except Exception:
                failures += 1
                import traceback
                traceback.print_exc()
                print("FAIL", name)
    shutil.rmtree(home, ignore_errors=True)
    sys.exit(1 if failures else 0)
