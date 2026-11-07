"""app_delivery: the Hermes iOS app on the owner's devices, for Hermes to decide.

app_devices lists what hermes-app can install on (paired once by cable, then
reached over the local network), with each one's last install and when its
signature expires. app_install queues a build and install (hermes-app's
launchd job does it, in Hermes' GUI session) and returns at once; its end
comes back to the chat that asked as an internal notification turn, through
the gateway's completion queue, as the sandbox plugin's does. config.json
(../default.nix) names the command and the state directory.
"""

from __future__ import annotations

import json
import logging
import subprocess
import threading
import time
import uuid
from pathlib import Path

logger = logging.getLogger(__name__)

DEVICES = {
    "name": "app_devices",
    "description": (
        "The owner's iPhones and iPads the Hermes app can be installed on (paired with this Mac), whether each is "
        "reachable now, its last install (version, pet, error) and when the app's signature expires. A device not "
        "listed was never plugged into this Mac: the owner must plug it in once (bootstrap-macos.sh app)."
    ),
    "parameters": {"type": "object", "properties": {}},
}
INSTALL = {
    "name": "app_install",
    "description": (
        "Rebuild the Hermes iOS app on this Mac (with the current pet as its icon), sign it and install it on the "
        "owner's devices over the network. Use it after a new pet, when the owner asks, or when app_devices shows "
        "a failed install. Without devices: those it is installed on already (or every paired one the first time). "
        "Returns at once; a notification comes when it ends (a build takes minutes). The signature is renewed by "
        "itself before it expires: no need to reinstall for that."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "devices": {"type": "array", "items": {"type": "string"}, "description": "Device ids (UDIDs) from app_devices."},
            "reason": {"type": "string", "description": "Why, in a few words (shown in the app's device list)."},
        },
    },
}
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
WAIT = 3 * 3600


def summary(done: dict, names: dict[str, str]) -> str:
    results = done.get("results") or {}
    if not results:
        return "App install: no device to install on. Check app_devices; the owner may need to plug one in once."
    parts = []
    for udid, result in results.items():
        name = names.get(udid) or udid
        if result.get("ok"):
            parts.append(f"{name}: installed {result.get('version')} ({result.get('build')}), "
                         f"signed until {result.get('profile_expires')}")
        else:
            parts.append(f"{name}: failed: {result.get('error')}")
    return "App install finished. " + "; ".join(parts) + f". Log: {done.get('log')}"


class Delivery:
    def __init__(self, config: dict, notify):
        self.command = config["command"]
        self.state_dir = Path(config["state_dir"])
        self.notify = notify
        self.poll = float(config.get("poll_seconds", 5))

    def _cli(self, *args: str, timeout: int = 180) -> dict:
        result = subprocess.run([self.command, *args], capture_output=True, text=True, timeout=timeout)
        try:
            return json.loads(result.stdout or result.stderr)
        except json.JSONDecodeError:
            return {"error": (result.stderr or result.stdout).strip()[-1000:] or f"exit {result.returncode}"}

    def devices(self) -> dict:
        return self._cli("devices")

    def install(self, devices: list[str], reason: str, routing: dict) -> dict:
        args = ["install", "--reason", reason or "asked by Hermes"]
        for udid in devices:
            args += ["--device", udid]
        started = self._cli(*args)
        if started.get("request"):
            threading.Thread(target=self._watch, args=(started["request"], routing), daemon=True,
                             name=f"app-install-{started['request']}").start()
        return started

    def _watch(self, request_id: str, routing: dict) -> None:
        path = self.state_dir / "requests" / "done" / f"{request_id}.json"
        deadline = time.monotonic() + WAIT
        while time.monotonic() < deadline:
            if path.exists():
                break
            time.sleep(self.poll)
        else:
            return
        try:
            done = json.loads(path.read_text())
            state = json.loads((self.state_dir / "delivery.json").read_text())
            names = {d["id"]: d.get("name") for d in state.get("devices") or []}
        except Exception:  # noqa: BLE001
            logger.exception("app_delivery: could not read the result of %s", request_id)
            return
        event = {
            # The gateway's completion watcher injects watch events as an
            # internal notification turn in the chat they name
            # (gateway/run.py _format_gateway_process_notification).
            "type": "watch_match",
            "event_id": uuid.uuid4().hex,
            "session_id": f"app-install-{request_id}",
            "command": f"app_install {request_id}",
            "pattern": "finished",
            "output": summary(done, names),
            "suppressed": 0,
            "started_at": done.get("at"),
            "task_id": "",
            "owner_task_id": "",
            "message_id": "",
            **{key: routing.get(key, "") for key in ROUTING},
        }
        try:
            self.notify(event)
        except Exception:  # noqa: BLE001
            logger.exception("app_delivery: the end of %s was not delivered", request_id)


def _routing() -> dict:
    try:
        from gateway.session_context import get_session_env
    except Exception:  # noqa: BLE001
        return {}
    return {key: get_session_env(var, "") for key, var in ROUTING.items()}


def _push_completion(event: dict) -> None:
    from tools.process_registry import process_registry

    process_registry.completion_queue.put(event)


def tools(delivery: Delivery) -> list[tuple[dict, object]]:
    return [
        (DEVICES, lambda args, **_: json.dumps(delivery.devices())),
        (INSTALL, lambda args, **_: json.dumps(delivery.install(
            [str(d) for d in args.get("devices") or []], str(args.get("reason") or ""), _routing()))),
    ]


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    config = json.loads((Path(get_hermes_home()) / "app-delivery.json").read_text())
    delivery = Delivery(config, notify=_push_completion)
    for schema, handler in tools(delivery):
        ctx.register_tool(name=schema["name"], toolset="app", schema=schema, handler=handler, emoji="📱")
