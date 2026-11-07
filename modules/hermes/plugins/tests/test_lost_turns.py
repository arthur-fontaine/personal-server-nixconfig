"""lost_turns against Hermes' own session store and authority: two real owner
epochs on one SQLite store, as upstream tests its automation settlement
(tests/gateway/test_unknown_automation_settles.py at the pinned revision)."""

from __future__ import annotations

import asyncio
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

TESTS = Path(__file__).resolve().parent
PLUGINS = TESTS.parent
sys.path.insert(0, str(PLUGINS))

OWNER = "4242"
os.environ["TELEGRAM_ALLOWED_USERS"] = f"{OWNER},77"

import lost_turns as lt  # noqa: E402

LOAD_DEADLINE = 10  # plugins.load_timeout_seconds in these homes


def plugin_home(home, enabled=("lost_turns",)):
    """A Hermes home with lost_turns installed as a user plugin, as on the server."""
    if "lost_turns" in enabled and not (home / "plugins" / "lost_turns").exists():
        shutil.copytree(PLUGINS / "lost_turns", home / "plugins" / "lost_turns",
                        ignore=shutil.ignore_patterns("__pycache__"))
    (home / "config.yaml").write_text(json.dumps({
        "plugins": {"enabled": list(enabled), "load_timeout_seconds": LOAD_DEADLINE,
                    "entries": {"lost_turns": {"allow_gateway_injection": True}}},
        # The server has one: it makes gateway.run's import wait for the plugins.
        "auxiliary": {"title_generation": {"enabled": False}},
    }))


def principal(chat, user, platform="telegram"):
    return f'messaging:[null,"{platform}","{chat}",null,"{user}"]'


class Peer:
    def __init__(self):
        self.frames = queue.Queue()

    def write(self, frame):
        self.frames.put(frame)
        return True


async def poll(predicate, what, timeout=30.0):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, f"timed out waiting for {what}"
        await asyncio.sleep(0.02)


async def lost_head(home, head_principal, *, follower=True, steered=()):
    """Owner 1 admits a head from ``head_principal`` and maybe a follower, claims
    the head and dies; owner 2 starts on the same store (the head is now unknown)."""
    from gateway.config import GatewayConfig, Platform
    from gateway.session import SessionSource, SessionStore
    from gateway.session_authority import initialize_session_authority
    from hermes_state_runtime import admit_session_input, claim_session_input

    os.environ["HERMES_HOME"] = str(home)
    store = SessionStore(home / "sessions", GatewayConfig())
    executed = []

    async def answer(event):
        from gateway.session_results import execution_result
        executed.append(event.text)
        execution_result.get()["result"] = {"final_response": "ACK_" + event.text, "completed": True, "messages": []}
        return "ACK_" + event.text

    runner = SimpleNamespace(_session_db=store._db, session_store=store, _draining=False,
                             _handle_message=answer, _adapter_for_source=lambda source: None)
    db = store._db
    db.create_session("s", source="telegram")
    first = await initialize_session_authority(runner, profile_id="p", instance_id="owner-1")
    head = admit_session_input(db, epoch=first.epoch, principal_id=head_principal, session_id="s",
                               request_id="469", payload={"text": "BUILD"})
    if follower:
        admit_session_input(db, epoch=first.epoch, principal_id=head_principal, session_id="s",
                            request_id="500", payload={"text": "FOLLOWER"})
    claim = claim_session_input(db, epoch=first.epoch, session_id="s")
    assert claim["admission_id"] == head["admission_id"]
    for n, text in enumerate(steered):
        # Sent mid-turn and handed to the running claim (busy_input_mode steer).
        from hermes_state_runtime import steer_session_input
        sent = admit_session_input(db, epoch=first.epoch, principal_id=head_principal, session_id="s",
                                   request_id=f"6{n}", payload={"text": text})
        steer_session_input(db, epoch=first.epoch, admission_id=sent["admission_id"], generation=claim["generation"])
    db.append_message("s", "user", "BUILD")
    db.append_message("s", "assistant", "", tool_calls=[{"id": "c1", "type": "function",
                                                         "function": {"name": "terminal", "arguments": "{}"}}])
    second = await initialize_session_authority(runner, profile_id="p", instance_id="owner-2")
    source = SessionSource(platform=Platform.TELEGRAM, chat_id=OWNER, user_id=OWNER)
    return store, runner, second, head["admission_id"], executed, source


def statuses(db):
    from hermes_state_runtime import list_session_admissions
    return [(r["payload"].get("text"), r["status"], r["outcome"])
            for r in list_session_admissions(db, session_id="s", pending_only=False)]


async def drain(authority, source):
    from gateway.session_authority import LiveSession
    from gateway.session_contract import SessionRef
    authority.sessions.setdefault("s", LiveSession(source, "s"))
    authority._schedule(SessionRef("p", "s"))
    live = authority.sessions["s"]
    await poll(lambda: live.task is not None and live.task.done(), "the drain")


def notices(db):
    return [m["content"] for m in db.get_messages("s") if m.get("display_kind") == "failed_turn"]


async def test_boot_settles_the_owners_turn_and_the_queue_runs(home):
    store, runner, authority, head, executed, source = await lost_head(home, principal(OWNER, OWNER))
    try:
        assert statuses(authority.db)[0] == ("BUILD", "unknown", None)
        runner.session_authority = authority
        runner.session_runtime_descriptor = {"state": "ready"}
        injected = []
        ctx = SimpleNamespace(inject_message=lambda text, origin: injected.append((text, origin)) or True)
        # Not live yet: settled in the store, before any drain, as at boot.
        await lt.at_boot(ctx, runner, ready_wait=5)
        assert statuses(authority.db)[0] == ("BUILD", "terminal", "interrupted")
        assert notices(authority.db) == [lt.NOTICE]
        # The startup recovery's drain then runs the queue; the lost input is never replayed.
        await drain(authority, source)
        assert executed == ["FOLLOWER"], executed
        assert statuses(authority.db)[1] == ("FOLLOWER", "terminal", "completed")
        assert injected == []  # something was queued: that turn tells Hermes
    finally:
        store.close_all_db_handles()


async def test_nothing_queued_gets_one_continuation(home):
    store, runner, authority, head, executed, source = await lost_head(home, principal(OWNER, OWNER), follower=False)
    try:
        runner.session_authority = authority
        runner.session_runtime_descriptor = {"state": "starting"}
        injected = []
        ctx = SimpleNamespace(inject_message=lambda text, origin: injected.append((text, origin)) or True)
        task = asyncio.ensure_future(lt.at_boot(ctx, runner, ready_wait=10))
        await poll(lambda: statuses(authority.db)[0][1] == "terminal", "the settlement")
        await asyncio.sleep(0.3)
        assert injected == []  # waits for the gateway to be ready
        runner.session_runtime_descriptor = {"state": "ready"}
        await poll(task.done, "the continuation")
        task.result()
        assert injected == [(lt.CONTINUE, {"platform": "telegram", "chat_id": OWNER,
                                           "chat_type": "dm", "user_id": OWNER})]
        assert lt.CONTINUE.startswith("[SYSTEM")  # guard: not the user's turn
    finally:
        store.close_all_db_handles()


async def test_messages_steered_into_the_lost_turn_are_quoted(home):
    store, runner, authority, head, executed, source = await lost_head(
        home, principal(OWNER, OWNER), follower=False, steered=["et le build ?", "laisse tomber"])
    try:
        # The recovery settled them with the lost claim: nothing queued, never replayed.
        assert [s[1:] for s in statuses(authority.db)[1:]] == [("terminal", "interrupted")] * 2
        runner.session_authority = authority
        runner.session_runtime_descriptor = {"state": "ready"}
        injected = []
        ctx = SimpleNamespace(inject_message=lambda text, origin: injected.append(text) or True)
        await lt.at_boot(ctx, runner, ready_wait=5)
        [notice] = notices(authority.db)
        assert notice.startswith(lt.NOTICE) and lt.STEERED in notice, notice
        assert notice.index("et le build ?") < notice.index("laisse tomber"), notice
        assert injected == [lt.CONTINUE]  # Hermes gets a turn to answer them
        await drain(authority, source)
        assert executed == []
    finally:
        store.close_all_db_handles()


async def test_loads_beside_the_gateway_import(home):
    """Hermes' own loader, under its deadline, while the main thread is still
    importing gateway.run (lost_turns_startup.py): register() returns at once
    and its hook stays registered."""
    state, user = home / "state", home / "user"
    state.mkdir()
    user.mkdir()
    plugin_home(state)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(user), "HERMES_HOME": str(state),
           "TELEGRAM_ALLOWED_USERS": OWNER}
    child = await asyncio.to_thread(
        subprocess.run, [sys.executable, "-I", str(TESTS / "lost_turns_startup.py")],
        env=env, capture_output=True, text=True, timeout=120)
    assert child.returncode == 0, child.stdout + child.stderr
    result = json.loads(child.stdout.strip().splitlines()[-1])
    assert result["held"], result
    assert result["found"] and result["error"] is None and result["enabled"], result
    assert result["elapsed"] < LOAD_DEADLINE, result
    assert any(h.endswith("lost_turns.before_dispatch") for h in result["hooks"]), result
    assert result["boot_thread"], result


async def test_the_boot_waits_for_the_runner_and_its_loop(home):
    store, runner, authority, head, executed, source = await lost_head(home, principal(OWNER, OWNER))
    published = {}
    lookup = lt._runner
    lt._runner = lambda: published.get("runner")
    try:
        injected = []
        ctx = SimpleNamespace(inject_message=lambda text, origin: injected.append(text) or True)
        found = []
        watcher = threading.Thread(target=lambda: found.append(lt.watch_boot(ctx, wait=30)), daemon=True)
        watcher.start()
        # GatewayRunner() publishes the runner, the authority comes next, the loop in start().
        runner._gateway_loop = None
        published["runner"] = runner
        runner.session_authority = authority
        runner.session_runtime_descriptor = {"state": "starting"}
        assert statuses(authority.db)[0] == ("BUILD", "unknown", None)  # nothing to run it on yet
        runner._gateway_loop = asyncio.get_running_loop()
        await poll(lambda: statuses(authority.db)[0][1] == "terminal", "the boot settlement")
        assert statuses(authority.db)[0] == ("BUILD", "terminal", "interrupted")
        await poll(lambda: found, "the watcher")
        assert found == [True]
        await drain(authority, source)
        assert executed == ["FOLLOWER"], executed
    finally:
        lt._runner = lookup
        store.close_all_db_handles()


async def test_the_boot_settles_a_session_the_recovery_already_mounted(home):
    store, runner, authority, head, executed, source = await lost_head(home, principal(OWNER, OWNER))
    try:
        # The startup recovery won the race: mounted, paused on the unknown head, silently.
        await drain(authority, source)
        assert executed == [] and statuses(authority.db)[0][1] == "unknown"
        runner.session_authority = authority
        runner.session_runtime_descriptor = {"state": "ready"}
        ctx = SimpleNamespace(inject_message=lambda *a, **k: True)
        await lt.at_boot(ctx, runner, ready_wait=5)
        live = authority.sessions["s"]
        await poll(lambda: executed == ["FOLLOWER"] and live.task.done(), "the follower")
        assert statuses(authority.db)[0] == ("BUILD", "terminal", "interrupted")
        assert not live.pause_notified
    finally:
        store.close_all_db_handles()


async def test_a_live_session_settles_before_the_owners_message(home):
    # Loaded by Hermes' own loader, the hook fired by Hermes' own dispatch.
    plugin_home(home)
    store, runner, authority, head, executed, source = await lost_head(home, principal(OWNER, OWNER))
    try:
        from hermes_cli.plugins import ainvoke_hook, discover_plugins
        await asyncio.to_thread(discover_plugins)
        # Live and paused, as after a worker lost while the gateway stayed up.
        await drain(authority, source)
        assert executed == [] and statuses(authority.db)[0][1] == "unknown"
        event = SimpleNamespace(source=source)
        assert await ainvoke_hook("pre_gateway_dispatch", event=event,
                                  gateway=SimpleNamespace(session_authority=authority),
                                  session_store=store) == []
        live = authority.sessions["s"]
        await poll(lambda: executed == ["FOLLOWER"] and live.task.done(), "the follower")
        assert statuses(authority.db)[0] == ("BUILD", "terminal", "interrupted")
        assert notices(authority.db) == [lt.NOTICE]
    finally:
        store.close_all_db_handles()


async def test_another_chat_still_pauses(home):
    for who in (principal("-100", OWNER), principal("77", "77"), principal(OWNER, OWNER, "discord")):
        sub = home / str(abs(hash(who)))
        sub.mkdir()
        store, runner, authority, head, executed, source = await lost_head(sub, who)
        try:
            runner.session_authority = authority
            runner.session_runtime_descriptor = {"state": "ready"}
            ctx = SimpleNamespace(inject_message=lambda *a, **k: True)
            await lt.at_boot(ctx, runner, ready_wait=5)
            other = SimpleNamespace(source=SimpleNamespace(platform="telegram", chat_id="77", user_id="77"))
            await lt.before_dispatch(event=other, gateway=SimpleNamespace(session_authority=authority))
            assert statuses(authority.db)[0] == ("BUILD", "unknown", None), who
        finally:
            store.close_all_db_handles()


def main() -> None:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for test in tests:
        with tempfile.TemporaryDirectory() as tmp:
            asyncio.run(test(Path(tmp)))
        print("ok", test.__name__)


if __name__ == "__main__":
    main()
