"""Sites' notifications, from the always-open Chrome in Hermes' session
(modules/hermes/agent/browser.nix), over the DevTools protocol.

Instagram: it sends Web Push to that Chrome (a Google build: Chrome for Testing
gets a push endpoint that Firebase rejects with 410). The push wakes its
service worker, which calls `showNotification`. Every new target is attached
paused (`Target.setAutoAttach`, `waitForDebuggerOnStart`); a service worker
gets the hook below before Instagram's code runs, then resumes. The hook hands
each notification to a CDP binding, and still shows it.

Discord: no push; the open tab shows its notifications (`new Notification`).
So the watcher keeps one Discord tab open (in the background, where Discord
notifies), attached with the hook on each document, and reopens it when it is
closed or taken elsewhere. Only that tab is hooked: `Runtime.enable` on a page
is what anti-bot scripts look for, so Instagram's tab is left alone.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from dataclasses import dataclass, field

import aiohttp

from .core import Chat, Message, Pipeline

log = logging.getLogger("hermes_events")

BINDING = "hermesNotify"
HOOK = """(() => {
  if (self.__hermesNotifyHooked) return;
  self.__hermesNotifyHooked = true;
  const send = (title, options) => {
    if (!self.location.hostname.endsWith('%(host)s')) return;
    try {
      const o = options || {};
      let data = '';
      try { data = o.data === undefined ? '' : JSON.stringify(o.data).slice(0, 2000); } catch (e) {}
      %(binding)s(JSON.stringify({title: String(title || ''), body: String(o.body || ''), tag: String(o.tag || ''), data, host: self.location.hostname}));
    } catch (e) {}
  };
  if (typeof ServiceWorkerRegistration !== 'undefined') {
    const show = ServiceWorkerRegistration.prototype.showNotification;
    ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
      send(title, options);
      return show.call(this, title, options);
    };
  }
  if (typeof window !== 'undefined' && typeof window.Notification === 'function') {
    const N = window.Notification;
    const Hooked = function (title, options) { send(title, options); return new N(title, options); };
    Hooked.prototype = N.prototype;
    Object.defineProperty(Hooked, 'permission', {get: () => N.permission});
    Hooked.requestPermission = N.requestPermission.bind(N);
    window.Notification = Hooked;
  }
})()"""

ORIGIN = "https://www.instagram.com"
DISCORD = "https://discord.com/channels/@me"

REPLY = {
    "instagram": "your instagram skill (https://www.instagram.com/direct/inbox/)",
    "discord": "your discord skill (https://discord.com/channels/@me)",
}


def hook(host: str = "instagram.com") -> str:
    return HOOK % {"binding": BINDING, "host": host}


def site_of(payload: dict) -> str:
    """Instagram's service worker, or else the one hooked page: Discord's tab."""
    return "instagram" if "instagram.com" in payload.get("host", "") else "discord"


_logged_fields: set[tuple[str, ...]] = set()


def _data_fields(data: str) -> tuple[str, ...]:
    try:
        value = json.loads(data) if data else None
    except ValueError:
        return ()
    return tuple(sorted(value)) if isinstance(value, dict) else ()


def notification_message(payload: dict, now: float) -> tuple[Chat, Message] | None:
    title, body = payload.get("title", "").strip(), payload.get("body", "").strip()
    if not (title or body):
        return None
    source = site_of(payload)
    # A DM's notification is titled with the sender (Discord: "Zoé", or
    # "Zoé (#general, Server)"; Instagram: the sender, or "Instagram" with
    # the sender leading the body, "zoe.martin: ce soir"): one chat per title, so
    # a burst batches. Instagram also titles some "Instagram" with the message
    # alone: then the sender is unknown, not the message's first words.
    if title and title.lower() not in ("instagram", "discord"):
        who = title
    elif ":" in body:
        who = body.split(":")[0][:60]
    else:
        who = ""
    fields = _data_fields(payload.get("data", ""))
    if fields and fields not in _logged_fields:
        # The names, never the values; the uri's shape, its digits masked.
        _logged_fields.add(fields)
        log.info("%s notification data fields: %s; uri like %s", source, ", ".join(fields),
                 re.sub(r"\d", "9", str(_data(payload).get("uri", "")))[:120])
    digest = hashlib.sha256(f"{payload.get('tag', '')}\0{title}\0{body}".encode()).hexdigest()[:16]
    chat = Chat(source, who or source, who or source.capitalize(), reply_hint=REPLY[source])
    sender = who or "someone (the notification does not name them)"
    return chat, Message(digest, now, sender, body or title)


instagram_message = notification_message


def _data(payload: dict) -> dict:
    try:
        value = json.loads(payload.get("data") or "null")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


# A DM's notification carries no sender (its data: details, notifType, pushId,
# targetUserId, uri), but its uri may name the thread, as Instagram's own push
# links do (direct_v2?id=<thread>&x=<item>, or /direct/t/<thread>).
_THREAD_IN_URI = re.compile(r"(?:direct_v2\?(?:[^ ]*&)?id=|/direct/t/|thread_id=)(\d{6,})")


def thread_id_of(payload: dict) -> str | None:
    match = _THREAD_IN_URI.search(str(_data(payload).get("uri", "")))
    return match.group(1) if match else None


# Instagram's web app id, which its pages send with every call to its API.
APP_ID = "936619743392459"


def item_text(item: dict) -> str:
    kind = item.get("item_type", "")
    if item.get("text"):
        return item["text"]
    if kind == "link":
        return (item.get("link") or {}).get("text") or "[link]"
    if kind == "reel_share":
        return f"[replied to a story] {(item.get('reel_share') or {}).get('text') or ''}".strip()
    if kind == "action_log":
        return (item.get("action_log") or {}).get("description") or ""
    return {"voice_media": "[voice message]", "like": "❤️", "media": "[photo]", "raven_media": "[photo]",
            "animated_media": "[GIF]", "media_share": "[shared post]", "clip": "[shared reel]",
            "story_share": "[shared story]"}.get(kind, f"[{kind}]" if kind else "")


def _same(a: str, b: str) -> bool:
    a, b = " ".join(a.split()).casefold(), " ".join(b.split()).casefold()
    return bool(a and b) and (a == b or (len(b) >= 12 and a.startswith(b.rstrip("…."))))


@dataclass
class Thread:
    id: str
    name: str
    is_group: bool
    users: dict[str, str]  # user id -> their name
    items: list[Message] = field(default_factory=list)  # oldest first; sender "me" for the user

    @classmethod
    def parse(cls, raw: dict, viewer: str = "") -> "Thread | None":
        tid = str(raw.get("thread_id") or raw.get("thread_v2_id") or "")
        if not tid:
            return None
        viewer = str(raw.get("viewer_id") or viewer)
        users = {str(u.get("pk") or u.get("pk_id") or ""): (u.get("full_name") or u.get("username") or "")
                 for u in raw.get("users") or [] if isinstance(u, dict)}
        items = []
        for item in raw.get("items") or []:
            text = item_text(item)
            try:
                moment = int(item.get("timestamp")) / 1e6
            except (TypeError, ValueError):
                continue
            if not text:
                continue
            sender = "me" if str(item.get("user_id")) == viewer else users.get(str(item.get("user_id")), "them")
            items.append(Message(str(item.get("item_id", "")), moment, sender, text))
        items.sort(key=lambda m: m.time)
        others = [n for n in users.values() if n]
        name = raw.get("thread_title") or ", ".join(others) or "Instagram"
        return cls(tid, name, bool(raw.get("is_group")), users, items)

    def sender_of(self, text: str) -> str | None:
        """Who sent the newest item reading `text`; in a one-to-one thread, the other."""
        for item in reversed(self.items):
            if item.sender != "me" and _same(item.text, text):
                return item.sender
        others = [n for n in self.users.values() if n]
        return others[0] if len(others) == 1 and not self.is_group else None

    def context(self, messages: list[Message], limit: int, cutoff: float):
        """Earlier items, before the ones the new messages are; answered when
        the user wrote after them."""
        from .history import Context

        pending = [m.text for m in messages]
        first = min(m.time for m in messages)
        oldest_new = None
        for item in reversed(self.items):
            if item.time < first - 300 or not pending:
                break
            match = next((t for t in pending if item.sender != "me" and _same(item.text, t)), None)
            if match is not None:
                pending.remove(match)
                oldest_new = item.time
        # Not found in the thread: the new ones are whatever came since `first`.
        boundary = oldest_new if oldest_new is not None else first
        answered = oldest_new is not None and any(
            i.sender == "me" and i.time > oldest_new for i in self.items)
        earlier = [i for i in self.items if i.time < boundary and i.time >= cutoff]
        return Context(earlier[-limit:], answered)


class Instagram:
    """Instagram's web API, read only (the inbox and a thread, never the call
    that marks a message seen), through the logged-in browser: a background
    tab on instagram.com/robots.txt, which runs none of Instagram's scripts,
    fetches it with the browser's own cookies, then closes."""

    def __init__(self, origin: str = ORIGIN):
        self.origin = origin
        self.cdp: CDP | None = None

    async def api(self, *paths: str) -> list[dict | None]:
        cdp = self.cdp
        if cdp is None:
            return [None] * len(paths)
        target = (await cdp.call("Target.createTarget", {"url": f"{self.origin}/robots.txt", "background": True}))["result"]["targetId"]
        try:
            session = (await cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True}))["result"]["sessionId"]
            for _ in range(50):
                here = await cdp.call("Runtime.evaluate", {"expression": "location.origin", "returnByValue": True}, session)
                if here.get("result", {}).get("result", {}).get("value") == self.origin:
                    break
                await asyncio.sleep(0.2)
            expression = """Promise.all(%s.map(async (p) => {
                try {
                  const r = await fetch(p, {credentials: 'include', headers: {'X-IG-App-ID': '%s', 'X-Requested-With': 'XMLHttpRequest'}});
                  return r.ok ? await r.text() : '';
                } catch (e) { return ''; }
              }))""" % (json.dumps(list(paths)), APP_ID)
            answer = await cdp.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True,
                                                         "returnByValue": True}, session)
            bodies = answer.get("result", {}).get("result", {}).get("value") or [""] * len(paths)
        finally:
            try:
                await cdp.call("Target.closeTarget", {"targetId": target})
            except Exception:
                pass
        out = []
        for body in bodies:
            try:
                out.append(json.loads(body) if body else None)
            except ValueError:
                out.append(None)
        return out

    async def thread(self, thread_id: str) -> Thread | None:
        if not thread_id.isdigit():
            return None
        try:
            (raw,) = await self.api(f"/api/v1/direct_v2/threads/{thread_id}/?limit=20")
        except Exception as err:
            log.warning("instagram thread %s: %s", thread_id, err)
            return None
        return Thread.parse(raw["thread"]) if raw and isinstance(raw.get("thread"), dict) else None

    async def find(self, text: str) -> Thread | None:
        """The thread whose latest items include `text`: the inbox, then the
        requests from people the user does not follow."""
        try:
            answers = await self.api("/api/v1/direct_v2/inbox/?limit=20&thread_message_limit=5",
                                     "/api/v1/direct_v2/pending_inbox/?limit=20")
        except Exception as err:
            log.warning("instagram inbox: %s", err)
            return None
        for raw in answers:
            if not raw:
                continue
            viewer = str((raw.get("viewer") or {}).get("pk") or "")
            for t in (raw.get("inbox") or {}).get("threads") or []:
                thread = Thread.parse(t, viewer)
                if thread and any(i.sender != "me" and _same(i.text, text) for i in thread.items):
                    return thread
        return None


async def resolve_instagram(instagram: Instagram, pipeline: Pipeline, payload: dict, chat: Chat,
                            message: Message) -> None:
    """The notification's thread, for its sender's name, one chat per thread
    and its history; the notification alone when it cannot be found."""
    try:
        tid = thread_id_of(payload)
        thread = await instagram.thread(tid) if tid else None
        thread = thread or await instagram.find(message.text)
    except Exception as err:
        log.warning("instagram: could not find the thread: %s", err)
        thread = None
    if thread is None:
        log.info("instagram: no thread found for a notification (%s)", "uri" if thread_id_of(payload) else "no uri")
        pipeline.message(chat, message)
        return
    sender = thread.sender_of(message.text) or (message.sender if chat.chat_id != "instagram" else
                                                "someone (the notification does not name them)")
    pipeline.message(Chat("instagram", thread.id, thread.name, thread.is_group, reply_hint=REPLY["instagram"]),
                     Message(message.id, message.time, sender, message.text))


class CDP:
    def __init__(self, ws):
        self.ws, self.n, self.pending = ws, 0, {}
        self.tasks: set[asyncio.Task] = set()

    def spawn(self, coroutine) -> None:
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def call(self, method: str, params: dict | None = None, session: str | None = None) -> dict:
        self.n += 1
        message = {"id": self.n, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        future = asyncio.get_running_loop().create_future()
        self.pending[self.n] = future
        await self.ws.send_str(json.dumps(message))
        return await asyncio.wait_for(future, 15)

    def resolve(self, message: dict) -> bool:
        future = self.pending.pop(message.get("id"), None)
        if future and not future.done():
            future.set_result(message)
        return future is not None


async def attached(cdp: CDP, params: dict, host: str) -> None:
    """Service workers only: a push wakes Instagram's even with no tab open,
    and leaving pages alone keeps `Runtime.enable`, which anti-bot scripts
    detect, out of the tab Hermes uses. A worker has no context until its
    script starts, so it pauses right before (an instrumentation breakpoint)
    and `paused` hooks it there; the hook itself checks the site."""
    session, info = params["sessionId"], params.get("targetInfo", {})
    log.debug("attached %s %s", info.get("type"), info.get("url"))
    try:
        if info.get("type") == "service_worker":
            await cdp.call("Runtime.enable", {}, session)
            await cdp.call("Runtime.addBinding", {"name": BINDING}, session)
            await cdp.call("Debugger.enable", {}, session)
            await cdp.call("Debugger.setInstrumentationBreakpoint", {"instrumentation": "beforeScriptExecution"}, session)
    except Exception as err:
        log.debug("could not hook %s: %s", info.get("url"), err)
    finally:
        if params.get("waitingForDebugger"):
            await cdp.call("Runtime.runIfWaitingForDebugger", {}, session)


async def paused(cdp: CDP, session: str, host: str) -> None:
    try:
        await cdp.call("Runtime.evaluate", {"expression": hook(host)}, session)
    except Exception as err:
        log.debug("could not hook a worker: %s", err)
    finally:
        await cdp.call("Debugger.resume", {}, session)


async def keep_discord(cdp: CDP, url: str, every: float = 60, host: str = "discord.com",
                       pipeline: Pipeline | None = None) -> None:
    """One Discord tab, open in the background and hooked; reopened when gone.
    Logged out, Discord sends it to /login, where nothing ever notifies: the
    user hears of it once."""
    target, warned = None, False
    while True:
        try:
            pages = (await cdp.call("Target.getTargets"))["result"]["targetInfos"]
            mine = next((t for t in pages if t["targetId"] == target), None)
            logged_out = bool(mine) and "/login" in mine.get("url", "")
            if not logged_out:
                warned = False
            elif not warned:
                warned = True
                log.warning("Discord is logged out in Hermes' Chrome")
                if pipeline is not None:
                    pipeline.system("discord-logged-out", "Discord is logged out in Hermes' Chrome, so its "
                                    "messages no longer reach Hermes: run scripts/bootstrap-macos.sh at the Mac to "
                                    "log in again.")
            if not mine or host not in mine.get("url", ""):
                target = (await cdp.call("Target.createTarget", {"url": "about:blank", "background": True}))["result"]["targetId"]
                session = (await cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True}))["result"]["sessionId"]
                await cdp.call("Runtime.enable", {}, session)
                await cdp.call("Runtime.addBinding", {"name": BINDING}, session)
                await cdp.call("Page.enable", {}, session)
                await cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": hook(host)}, session)
                await cdp.call("Page.navigate", {"url": url}, session)
                log.info("watching Discord's notifications")
        except Exception as err:
            log.warning("could not keep the Discord tab: %s", err)
        await asyncio.sleep(every)


async def instagram_watch(pipeline: Pipeline, devtools: str, host: str = "instagram.com",
                          origin: str = ORIGIN, discord: str | None = None,
                          discord_host: str = "discord.com", discord_origin: str = "https://discord.com",
                          instagram: Instagram | None = None) -> None:
    """Stays attached to the browser at `devtools` (http://127.0.0.1:<port>), reconnecting."""
    delay = 5
    while True:
        try:
            async with aiohttp.ClientSession() as http:
                async with http.get(f"{devtools}/json/version") as response:
                    url = (await response.json())["webSocketDebuggerUrl"]
                async with http.ws_connect(url, max_msg_size=0) as ws:
                    cdp = CDP(ws)
                    if instagram:
                        instagram.cdp = cdp
                    reader = asyncio.create_task(read(ws, cdp, pipeline, host, instagram))
                    await cdp.call("Browser.grantPermissions", {"origin": origin, "permissions": ["notifications"]})
                    await cdp.call("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": True, "flatten": True})
                    log.info("watching Instagram's notifications")
                    if discord:
                        await cdp.call("Browser.grantPermissions", {"origin": discord_origin, "permissions": ["notifications"]})
                        cdp.spawn(keep_discord(cdp, discord, host=discord_host, pipeline=pipeline))
                    delay = 5
                    await reader
        except Exception as err:
            log.warning("browser at %s unavailable: %s", devtools, err)
        await asyncio.sleep(delay)
        delay = min(delay * 2, 300)


async def read(ws, cdp: CDP, pipeline: Pipeline, host: str, instagram: Instagram | None = None) -> None:
    async for frame in ws:
        if frame.type != aiohttp.WSMsgType.TEXT:
            continue
        message = json.loads(frame.data)
        if cdp.resolve(message):
            continue
        method, params = message.get("method"), message.get("params", {})
        if method == "Target.attachedToTarget":
            cdp.spawn(attached(cdp, params, host))
        elif method == "Debugger.paused" and message.get("sessionId"):
            cdp.spawn(paused(cdp, message["sessionId"], host))
        elif method == "Runtime.bindingCalled" and params.get("name") == BINDING:
            try:
                payload = json.loads(params.get("payload", "{}"))
                parsed = notification_message(payload, time.time())
            except ValueError:
                continue
            if parsed and instagram and parsed[0].source == "instagram":
                cdp.spawn(resolve_instagram(instagram, pipeline, payload, *parsed))
            elif parsed:
                pipeline.message(*parsed)
