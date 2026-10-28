"""Sources with no push: polled, each on its own interval, with what they have
already seen kept in the state directory. A first poll only records what is
there, so a restart never replays the past.

- calendar, mail: iMCP's tools (events_fetch, mail_messages_search), over its
  stdio MCP server, as the trusted client "hermes-events"
- reminders: `remindctl show --json`
- calls: macOS' call history database (Full Disk Access)
- files: new files in the folders given
- github: `gh api notifications`
- runpod: pods left running (money), from its REST API
- system: this Mac's disk, power, services and SSH logins (trusted, no model)
"""

from __future__ import annotations

import asyncio
import glob
import hashlib
import json
import logging
import os
import shutil
import sqlite3
import time
from datetime import datetime, timedelta, timezone

import aiohttp

from .core import Pipeline, parse_time

log = logging.getLogger("hermes_events")


class State:
    """A poller's memory: one JSON file."""

    def __init__(self, path: str):
        self.path = path
        try:
            with open(path) as f:
                self.data = json.load(f)
        except (OSError, ValueError):
            self.data = {}

    def save(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path + ".tmp", "w") as f:
            json.dump(self.data, f)
        os.replace(self.path + ".tmp", self.path)

    def new(self, name: str, ids: list[str], keep: int = 5000, wait_for_data: bool = False) -> list[str]:
        """The ids not seen before; the first time, none (it only records).
        `wait_for_data`: an empty first answer (a permission not granted yet)
        records nothing, so what appears once granted is not all taken for new."""
        if wait_for_data and not ids and name not in self.data:
            return []
        first = name not in self.data
        known = set(self.data.get(name, []))
        fresh = [i for i in ids if i not in known]
        self.data[name] = (self.data.get(name, []) + fresh)[-keep:]
        return [] if first else fresh


async def run(*command: str, timeout: float = 60) -> str:
    process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE,
                                                   stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(process.communicate(), timeout)
    except asyncio.TimeoutError:
        process.kill()
        raise
    if process.returncode:
        raise RuntimeError(f"{command[0]} exited {process.returncode}: {err.decode()[:200]}")
    return out.decode()


def items(value) -> list[dict]:
    """The list of objects in a tool's JSON, wherever it sits."""
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    if isinstance(value, dict):
        for key in ("items", "events", "reminders", "messages", "results", "itemListElement", "data"):
            if isinstance(value.get(key), list):
                return items(value[key])
        return [value] if value.get("@type") or value.get("id") else []
    return []


def field(item: dict, *names: str, default=""):
    for name in names:
        if item.get(name) not in (None, ""):
            return item[name]
    return default


class MCP:
    """A minimal stdio MCP client (JSON-RPC, one message per line)."""

    def __init__(self, command: list[str], name: str = "hermes-events"):
        self.command, self.name, self.process, self.n = command, name, None, 0
        self.lock = asyncio.Lock()

    async def _start(self) -> None:
        self.process = await asyncio.create_subprocess_exec(
            *self.command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, limit=1 << 24)
        await self._request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                           "clientInfo": {"name": self.name, "version": "1"}})
        await self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    async def _send(self, message: dict) -> None:
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        await self.process.stdin.drain()

    async def _request(self, method: str, params: dict) -> dict:
        self.n += 1
        await self._send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        while True:
            line = await asyncio.wait_for(self.process.stdout.readline(), 120)
            if not line:
                raise RuntimeError("MCP server closed")
            message = json.loads(line)
            if message.get("id") == self.n:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message["result"]

    async def call(self, tool: str, arguments: dict):
        async with self.lock:
            try:
                if self.process is None or self.process.returncode is not None:
                    await self._start()
                result = await self._request("tools/call", {"name": tool, "arguments": arguments})
            except Exception:
                if self.process and self.process.returncode is None:
                    self.process.kill()
                self.process = None
                raise
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {result.get('content')}")
        if result.get("structuredContent") is not None:
            return result["structuredContent"]
        text = "".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        try:
            return json.loads(text)
        except ValueError:
            return text


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def when(value: str) -> str:
    try:
        return datetime.fromtimestamp(parse_time(value)).strftime("%a %d %b %H:%M")
    except (ValueError, TypeError):
        return str(value)


async def calendar(pipeline: Pipeline, state: State, imcp: MCP, lead_minutes: int = 30) -> None:
    now = datetime.now(timezone.utc)
    events = items(await imcp.call("events_fetch", {"start": iso(now), "end": iso(now + timedelta(days=14))}))
    by_id = {}
    for event in events:
        start = str(field(event, "startDate", "start"))
        ident = str(field(event, "identifier", "@id", "id", default=f"{field(event, 'name', 'title')}@{start}"))
        by_id[f"{ident}@{start}"] = event
    for key in state.new("calendar", list(by_id), wait_for_data=True):
        event = by_id[key]
        title, start = field(event, "name", "title", default="(untitled)"), str(field(event, "startDate", "start"))
        details = f"{title}, {when(start)}" + (f", {field(event, 'location')}" if field(event, "location") else "")
        pipeline.notice("calendar", key, f"New event in the calendar: {title}", details, id=f"new:{key}")
    for key, event in by_id.items():
        start = str(field(event, "startDate", "start"))
        try:
            soon = 0 <= parse_time(start) - time.time() <= lead_minutes * 60
        except (ValueError, TypeError):
            continue
        if soon and not event.get("isAllDay"):
            title = field(event, "name", "title", default="(untitled)")
            where = field(event, "location")
            pipeline.notice("calendar", key, f"Starting soon: {title}", f"{title}, {when(start)}" + (f", at {where}" if where else ""),
                            id=f"soon:{key}", screen=False)


async def mail(pipeline: Pipeline, state: State, imcp: MCP) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=2)
    messages = items(await imcp.call("mail_messages_search", {"isRead": False, "start": iso(since), "limit": 30}))
    by_id = {str(field(m, "@id", "id", "identifier", default=hashlib.sha1(json.dumps(m, sort_keys=True).encode()).hexdigest())): m
             for m in messages}
    for key in state.new("mail", list(by_id), wait_for_data=True):
        m = by_id[key]
        sender = field(m, "sender", "from", "author", default="someone")
        if isinstance(sender, dict):
            sender = field(sender, "name", "email", default="someone")
        subject = field(m, "subject", "name", "headline", default="(no subject)")
        pipeline.notice("mail", key, f"New mail from {sender}: {subject}",
                        str(field(m, "snippet", "preview", "description", "text"))[:1500], id=key)


async def reminders(pipeline: Pipeline, state: State, remindctl: str, lead_minutes: int = 15) -> None:
    listed = items(json.loads(await run(remindctl, "show", "upcoming", "--json")))
    listed += items(json.loads(await run(remindctl, "show", "overdue", "--json")))
    for r in listed:
        due = field(r, "dueDate")
        if r.get("isCompleted") or not due:
            continue
        try:
            left = parse_time(str(due)) - time.time()
        except (ValueError, TypeError):
            continue
        if left <= lead_minutes * 60:
            title = field(r, "title", default="(untitled)")
            pipeline.notice("reminders", str(r.get("id")), f"Reminder due: {title}",
                            f"{title}, due {when(str(due))}" + (f"\n{r['notes']}" if r.get("notes") else ""),
                            id=f"{r.get('id')}@{due}", screen=False)


# Core Data dates count from 2001-01-01.
APPLE_EPOCH = 978307200


async def calls(pipeline: Pipeline, state: State, database: str) -> None:
    if not os.path.exists(database):
        return
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=5) as db:
        rows = db.execute("SELECT Z_PK, ZDATE, ZADDRESS, ZNAME FROM ZCALLRECORD "
                          "WHERE ZANSWERED = 0 AND ZORIGINATED = 0 ORDER BY Z_PK DESC LIMIT 50").fetchall()
    by_id = {str(pk): (date, address, name) for pk, date, address, name in rows}
    for key in state.new("calls", list(by_id)):
        date, address, name = by_id[key]
        who = name or address or "an unknown number"
        at = datetime.fromtimestamp((date or 0) + APPLE_EPOCH).strftime("%H:%M")
        pipeline.notice("calls", key, f"Missed call from {who}", f"Missed call from {who} ({address}) at {at}", id=key)


async def files(pipeline: Pipeline, state: State, folders: list[str]) -> None:
    found = {}
    for folder in folders:
        for path in glob.glob(os.path.join(os.path.expanduser(folder), "*")):
            name = os.path.basename(path)
            if name.startswith(".") or name.endswith((".crdownload", ".download", ".part", ".icloud")):
                continue
            found[path] = name
    for path in state.new("files", list(found)):
        pipeline.notice("files", path, f"New file: {found[path]}", f"{path}", id=path)


async def github(pipeline: Pipeline, state: State, gh: str) -> None:
    listed = items(json.loads(await run(gh, "api", "notifications")))
    by_id = {f"{n.get('id')}@{n.get('updated_at')}": n for n in listed}
    for key in state.new("github", list(by_id)):
        n = by_id[key]
        subject, repo = n.get("subject", {}), n.get("repository", {}).get("full_name", "")
        pipeline.notice("github", key, f"GitHub ({n.get('reason')}): {subject.get('title')}",
                        f"{subject.get('type')} in {repo}: {subject.get('title')}", id=key)


async def runpod(pipeline: Pipeline, state: State, api_key: str, hours=(2, 6, 12, 24, 48)) -> None:
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get("https://rest.runpod.io/v1/pods", headers={"Authorization": f"Bearer {api_key}"}) as r:
            r.raise_for_status()
            pods = items(await r.json())
    running = state.data.setdefault("runpod_since", {})
    # Thresholds already reported, per pod: kept as long as it runs.
    told = state.data.setdefault("runpod_told", {})
    now = time.time()
    current, still_told = {}, {}
    for pod in pods:
        if field(pod, "desiredStatus", "status") != "RUNNING":
            continue
        pid = str(pod.get("id"))
        current[pid] = running.get(pid, now)
        elapsed = (now - current[pid]) / 3600
        still_told[pid] = told.get(pid, [])
        due = [h for h in hours if elapsed >= h and h not in still_told[pid]]
        if due:
            h, cost = max(due), pod.get("costPerHr")
            still_told[pid] += due
            pipeline.system(f"runpod:{pid}:{h}:{int(current[pid])}", f"RunPod: the pod {field(pod, 'name', default=pid)} has been running for "
                            f"{h} h" + (f" (${cost}/h)" if cost else "") + ". Stop it if you are done.")
    state.data["runpod_since"], state.data["runpod_told"] = current, still_told


class Health:
    """Transitions only: a service going down twice in a row, and back up."""

    def __init__(self):
        self.down: dict[str, int] = {}

    def report(self, pipeline: Pipeline, name: str, ok: bool) -> None:
        misses = 0 if ok else self.down.get(name, 0) + 1
        if misses == 2:
            pipeline.system(f"down:{name}:{int(time.time())}", f"⚠️ {name} is not answering.")
        if ok and self.down.get(name, 0) >= 2:
            pipeline.system(f"up:{name}:{int(time.time())}", f"✅ {name} is back.")
        self.down[name] = misses


async def system(pipeline: Pipeline, state: State, health: Health, services: dict[str, str]) -> None:
    usage = shutil.disk_usage("/")
    if usage.free / usage.total < 0.1:
        pipeline.system(f"disk:{datetime.now():%Y-%m-%d}", f"💾 The disk is almost full: {usage.free // 2**30} GB left.")
    power = await run("/usr/bin/pmset", "-g", "batt")
    on_battery = "'Battery Power'" in power
    if on_battery != state.data.get("on_battery", False):
        pipeline.system(f"power:{int(time.time())}", "🔋 On battery: the power is out." if on_battery else "🔌 Power is back.")
        state.data["on_battery"] = on_battery
    timeout = aiohttp.ClientTimeout(total=10)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        for name, url in services.items():
            try:
                async with session.get(url) as r:
                    health.report(pipeline, name, r.status < 500)
            except Exception:
                health.report(pipeline, name, False)
    # A session's line changes when it ends ("still logged in", then its
    # length): only its start (user, tty, host, date) names it.
    logins = {}
    for line in (await run("/usr/bin/last", "-20")).splitlines():
        if not line or line.startswith(("wtmp", "reboot", "shutdown")) or not (" ttys" in line or " ssh" in line):
            continue
        start = " ".join(line.split("still logged in")[0].split(" - ")[0].split())
        logins[hashlib.sha1(start.encode()).hexdigest()] = start
    for key in state.new("logins", list(logins)):
        pipeline.system(f"login:{key}", f"🔑 New login: {logins[key]}")


async def every(seconds: float, name: str, poll, state: State) -> None:
    while True:
        try:
            await poll()
            state.save()
        except Exception as err:
            log.warning("%s poll failed: %s", name, err)
        await asyncio.sleep(seconds)
