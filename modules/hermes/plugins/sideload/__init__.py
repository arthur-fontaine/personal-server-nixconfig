"""sideload: Hermes' access to the sideload service (modules/sideload,
docs/sideload.md), which installs iOS apps on the owner's devices from this
Mac and keeps them signed. Every tool calls its CLI (config.json names it);
the service's state stays its own.

- sideload_devices: the paired iPhones and iPads, reachable or not, the apps
  sideloaded on each.
- sideload_apps: the apps it knows (declared ones, the Hermes app among them,
  and those added), where each is installed and when its signature expires;
  with the free team's limits (3 sideloaded apps per device, 10 new App IDs
  per 7 days), so Hermes sees them before it asks for more.
- sideload_install: add an app if new (an .ipa by path or URL, a Telegram
  attachment's local path, a big-file link; or an Xcode project by path or
  git URL), then build or re-sign and install it. Returns at once; the end
  comes back to the chat that asked as a notification turn, through the
  gateway's completion queue.
- sideload_remove: uninstall an app from some or all devices, and optionally
  forget it.
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
    "name": "sideload_devices",
    "description": (
        "The owner's iPhones and iPads apps can be sideloaded on (paired once with this Mac), whether each is "
        "reachable now, and the apps installed on each. A device not listed was never plugged in: the owner must "
        "plug it in once (bootstrap-macos.sh sideload-devices)."),
    "parameters": {"type": "object", "properties": {}},
}
APPS = {
    "name": "sideload_apps",
    "description": (
        "The iOS apps this Mac installs and keeps signed (the Hermes app is `hermes`), where each is installed, its "
        "version and when its signature expires, plus the signing team's limits: a free team allows 3 sideloaded "
        "apps per device and 10 new App IDs per 7 days (an app's extensions each take one). Check before installing."),
    "parameters": {"type": "object", "properties": {}},
}
INSTALL = {
    "name": "sideload_install",
    "description": (
        "Install an iOS app on the owner's devices and keep it signed. For an app sideload already knows "
        "(sideload_apps), give only `app`: it is rebuilt (or re-signed) and installed again — for the Hermes app, "
        "`hermes`, after a new pet or when the owner asks. For a new one, also give `ipa` (a path, an attachment's "
        "local path, or an http(s) URL) or `project` (an Xcode project's directory or a git URL; `scheme` when not "
        "the project's name). A free team re-signs bundle ids as its own and drops an .ipa's extensions. Returns at "
        "once; a notice comes when it ends (a build takes minutes). Renewal before expiry happens by itself."),
    "parameters": {"type": "object", "required": ["app"], "properties": {
        "app": {"type": "string", "description": "A short name: lowercase letters, digits, '.', '_', '-'."},
        "ipa": {"type": "string", "description": "A new app's .ipa: a path or an http(s) URL."},
        "project": {"type": "string", "description": "A new app's Xcode project: a directory or a git URL."},
        "scheme": {"type": "string"},
        "ref": {"type": "string", "description": "A git URL's branch or tag."},
        "name": {"type": "string", "description": "A display name."},
        "devices": {"type": "array", "items": {"type": "string"}, "description": "UDIDs from sideload_devices; none: where it is installed, else every paired device."},
        "reason": {"type": "string", "description": "Why, in a few words."},
    }},
}
REMOVE = {
    "name": "sideload_remove",
    "description": "Uninstall a sideloaded app from the owner's devices (all of them without `devices`); `forget` also drops an added app from the list.",
    "parameters": {"type": "object", "required": ["app"], "properties": {
        "app": {"type": "string"},
        "devices": {"type": "array", "items": {"type": "string"}},
        "forget": {"type": "boolean"},
    }},
}

# What routes the completion back to the chat that asked (the gateway's
# session context, as tools/terminal_tool_background.py reads it).
ROUTING = {
    "platform": "HERMES_SESSION_PLATFORM", "chat_id": "HERMES_SESSION_CHAT_ID",
    "chat_type": "HERMES_SESSION_CHAT_TYPE", "thread_id": "HERMES_SESSION_THREAD_ID",
    "user_id": "HERMES_SESSION_USER_ID", "user_name": "HERMES_SESSION_USER_NAME",
    "session_key": "HERMES_SESSION_KEY", "parent_session_id": "HERMES_SESSION_ID",
}
WAIT = 3 * 3600


def summary(app: str, done: dict, names: dict) -> str:
    results = done.get("results") or {}
    verb = "removal" if done.get("action") == "remove" else "install"
    if not results:
        return f"Sideload {verb} of {app}: no device. Check sideload_devices; the owner may need to plug one in once."
    parts = []
    for udid, r in results.items():
        name = names.get(udid) or udid
        if r.get("ok") and r.get("removed"):
            parts.append(f"{name}: removed")
        elif r.get("ok"):
            parts.append(f"{name}: installed {r.get('version')} ({r.get('build')}), signed until {r.get('profile_expires')}")
        else:
            parts.append(f"{name}: failed: {r.get('error')}")
    return f"Sideload {verb} of {app} finished. " + "; ".join(parts) + f". Log: {done.get('log')}"


class Sideload:
    def __init__(self, config: dict, notify):
        self.command = config["command"]
        self.state_dir = Path(config["state_dir"])
        self.notify = notify
        self.poll = float(config.get("poll_seconds", 5))

    def cli(self, *args: str, timeout: int = 900) -> dict:
        try:
            result = subprocess.run([self.command, *args], capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            return {"error": f"sideload did not answer ({type(error).__name__})"}
        try:
            return json.loads(result.stdout or result.stderr)
        except json.JSONDecodeError:
            return {"error": (result.stderr or result.stdout).strip()[-1000:] or f"exit {result.returncode}"}

    def devices(self) -> dict:
        return self.cli("devices")

    def apps(self) -> dict:
        return {**self.cli("apps"), "limits": self.cli("limits")}

    def install(self, args: dict, routing: dict) -> dict:
        app = str(args.get("app") or "")
        if args.get("ipa") or args.get("project"):
            add = ["add", app, "--ipa", str(args["ipa"])] if args.get("ipa") else ["add", app, "--project", str(args["project"])]
            for key in ("scheme", "ref", "name"):
                if args.get(key):
                    add += [f"--{key}", str(args[key])]
            added = self.cli(*add)
            if added.get("error"):
                return added
        return self._queue("install", app, args, routing)

    def remove(self, args: dict, routing: dict) -> dict:
        started = self._queue("remove", str(args.get("app") or ""), args, routing,
                              then_forget=bool(args.get("forget")))
        return started

    def _queue(self, action: str, app: str, args: dict, routing: dict, then_forget: bool = False) -> dict:
        cli = [action, app, "--reason", str(args.get("reason") or "asked by Hermes")]
        for udid in args.get("devices") or []:
            cli += ["--device", str(udid)]
        started = self.cli(*cli, timeout=120)
        if started.get("request"):
            threading.Thread(target=self._watch, args=(app, started["request"], routing, then_forget), daemon=True,
                             name=f"sideload-{started['request']}").start()
        return started

    def _watch(self, app: str, request_id: str, routing: dict, then_forget: bool) -> None:
        path = self.state_dir / "requests" / "done" / f"{request_id}.json"
        deadline = time.monotonic() + WAIT
        while not path.exists():
            if time.monotonic() > deadline:
                return
            time.sleep(self.poll)
        try:
            done = json.loads(path.read_text())
            state = json.loads((self.state_dir / "state.json").read_text())
            names = {d["id"]: d.get("name") for d in state.get("devices") or []}
        except Exception:  # noqa: BLE001
            logger.exception("sideload: could not read the result of %s", request_id)
            return
        output = summary(app, done, names)
        if then_forget:
            forgot = self.cli("forget", app)
            output += f" {'Forgotten.' if forgot.get('forgotten') else 'Not forgotten: ' + str(forgot.get('error'))}"
        event = {
            # The gateway injects watch events as an internal notification turn
            # in the chat they name (gateway/run.py _format_gateway_process_notification).
            "type": "watch_match", "event_id": uuid.uuid4().hex, "session_id": f"sideload-{request_id}",
            "command": f"sideload {done.get('action', 'install')} {app}", "pattern": "finished", "output": output,
            "suppressed": 0, "started_at": done.get("at"), "task_id": "", "owner_task_id": "", "message_id": "",
            **{key: routing.get(key, "") for key in ROUTING},
        }
        try:
            self.notify(event)
        except Exception:  # noqa: BLE001
            logger.exception("sideload: the end of %s was not delivered", request_id)


def _routing() -> dict:
    try:
        from gateway.session_context import get_session_env
    except Exception:  # noqa: BLE001
        return {}
    return {key: get_session_env(var, "") for key, var in ROUTING.items()}


def _push_completion(event: dict) -> None:
    from tools.process_registry import process_registry

    process_registry.completion_queue.put(event)


def tools(s: Sideload) -> list:
    return [
        (DEVICES, lambda args, **_: json.dumps(s.devices())),
        (APPS, lambda args, **_: json.dumps(s.apps())),
        (INSTALL, lambda args, **_: json.dumps(s.install(args or {}, _routing()))),
        (REMOVE, lambda args, **_: json.dumps(s.remove(args or {}, _routing()))),
    ]


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    config = json.loads((Path(get_hermes_home()) / "sideload" / "config.json").read_text())
    s = Sideload(config, notify=_push_completion)
    for schema, handler in tools(s):
        ctx.register_tool(name=schema["name"], toolset="sideload", schema=schema, handler=handler, emoji="📱")
