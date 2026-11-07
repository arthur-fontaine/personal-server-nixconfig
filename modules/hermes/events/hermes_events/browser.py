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
import contextlib
import hashlib
import json
import logging
import os
import pathlib
import re
import time
from dataclasses import dataclass, field

import aiohttp

from .core import Chat, Message, Pipeline

log = logging.getLogger("hermes_events")

# Hermes' skill loads it into a page to read and send DMs; the daemon loads it
# to read the inbox the same way (hermes_events/../agent/skills/instagram).
DIRECT_JS = (pathlib.Path(__file__).with_name("direct.js")).read_text()

# A thread's newest message, as the app previews it: "You: …" is the user's own,
# and so are the app's own phrasings of what they did ("You sent a video.").
# The separator is required: a friend's "Vous venez ce soir ?" starts with
# "Vous" too.
_OWN = re.compile(
    r"^(?:(?:you|vous)\s*:"
    r"|you (?:sent|replied|reacted|liked|shared|unsent|mentioned)\b"
    r"|vous avez (?:envoyé|répondu|réagi|aimé|partagé|retiré|mentionné)\b)",
    re.IGNORECASE)

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
    unnamed = ("instagram", "discord", "replied to your story")
    if title and title.lower() not in unnamed:
        who = title
    elif ":" in body and body.split(":")[0].strip().lower() not in unnamed:
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


_PREFIX = re.compile(r"^(?:replied to your story:\s*|\[replied to a story\]\s*)+")


def _same(a: str, b: str) -> bool:
    """A thread's item and a notification's body, which Instagram may clip
    ("…") or prefix ("Replied to your story: …")."""
    a, b = (_PREFIX.sub("", " ".join(t.split()).casefold()).strip() for t in (a, b))
    if not (a and b):
        return False
    short, long = sorted((a.rstrip("…."), b.rstrip("….")), key=len)
    return a == b or (len(short) >= 8 and short in long)


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


def thread_from_inbox(row: dict, tail: list[dict] = ()) -> Thread | None:
    """An inbox row as a Thread: its name, its people, its newest message, and
    the previews the inbox showed before them.

    Nothing here opens a thread: that marks its messages seen, and the user
    would then get no notification on their phone. The inbox is what this
    reads, so `tail` is the thread's last few previews as earlier passed them
    — enough for the screening to read "Bubble tea ?" and "?" as one exchange
    instead of two unanswerable fragments.
    """
    tid = str(row.get("id") or "")
    if not tid:
        return None
    names = [str(u) for u in row.get("users") or [] if u]
    users = {f"u{i}": name for i, name in enumerate(names)}
    text = str(row.get("text") or "").strip()
    group = bool(row.get("group"))
    # The tail was recorded from this same read, so its last entry is the
    # newest message itself: appended again below, it would read as two.
    at = row.get("at")
    items = [_tail_message(entry) for entry in tail
             if not (str(entry.get("text") or "").strip() == text and entry.get("at") == at)]
    items = [m for m in items if m is not None]
    if text:
        millis = row.get("at")
        when = float(millis) / 1000 if isinstance(millis, (int, float)) else time.time()
        # One person, one name: the sender. A group, or the user's own message,
        # leaves the row carrying the name of the thread and nothing more.
        if _OWN.match(text):
            sender = "me"
        elif len(names) == 1 and not group:
            sender = names[0]
        else:
            # A group's preview leads with who wrote ("zoe.martin: on mange
            # où ?"); a name that is not one of its people is the text's own.
            lead = text.split(":", 1)[0].strip() if ":" in text else ""
            sender = lead if lead in names else ""
        items.append(Message("", when, sender, text))
    return Thread(tid, str(row.get("name") or ""), group, users, items)


def _tail_message(entry: dict) -> Message | None:
    text = str(entry.get("text") or "").strip()
    at = entry.get("at")
    if not text or not isinstance(at, (int, float)):
        return None
    return Message("", float(at) / 1000, "me" if _OWN.match(text) else "", text)


INBOX_JS = "typeof __ig === 'object' ? JSON.stringify(__ig.inbox()) : ''"

# Instagram's own control for turning its notifications on, in the page.
PUSH_JS = """(async () => {
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = reg ? await reg.pushManager.getSubscription() : null;
  const label = /^(turn on notifications?|enable notifications?|activer les notifications?)$/i;
  const control = [...document.querySelectorAll('[role="button"], button, a')]
    .find((el) => label.test((el.getAttribute('aria-label') || el.innerText || '').trim()));
  return JSON.stringify({
    permission: typeof Notification === 'undefined' ? 'unsupported' : Notification.permission,
    subscribed: Boolean(sub),
    control: control ? (control.getAttribute('aria-label') || control.innerText || '').trim() : null,
  });
})()"""

CLICK_JS = """(() => {
  const label = /^(turn on notifications?|enable notifications?|activer les notifications?)$/i;
  const control = [...document.querySelectorAll('[role="button"], button, a')]
    .find((el) => label.test((el.getAttribute('aria-label') || el.innerText || '').trim()));
  if (!control) return 'gone';
  control.click();
  return 'clicked';
})()"""


class Instagram:
    """Instagram's DM inbox, read from the page itself.

    Its DM API is gone (`/api/v1/direct_v2/…` answers 404, with the logged-out
    page), and the calls the app makes now are signed: a hand-built request
    would be an unofficial client that breaks with every release. So the same
    script Hermes' skill uses (direct.js) goes into a background tab as a
    document-start script, reads the app's own traffic, and the tab closes.
    """

    CACHE_SECONDS = 120
    # How many of a thread's previews to remember: a burst ("Bubble tea ?",
    # then "?" an hour later) is one exchange, and the screening needs the
    # earlier line to see the second as a question rather than a fragment.
    TAIL = 8

    def __init__(self, origin: str = ORIGIN, tails_path: str | None = None):
        self.origin = origin
        self.cdp: CDP | None = None
        self._rows: list[dict] = []
        self._read_at = 0.0
        self._reading = asyncio.Lock()
        # thread id -> the inbox previews seen so far, oldest first. Kept on
        # disk: a notification that lands hours after the one it answers still
        # finds what came before it.
        self.tails_path = tails_path
        self._tails: dict[str, list[dict]] = self._load_tails()

    async def inbox(self, refresh: bool = False) -> list[dict]:
        """The inbox rows, read at most once per CACHE_SECONDS: a burst of
        notifications is one read, not one tab each."""
        if self.cdp is None:
            return []
        fresh = time.monotonic() - self._read_at <= self.CACHE_SECONDS
        if refresh or not fresh:
            async with self._reading:
                if refresh or time.monotonic() - self._read_at > self.CACHE_SECONDS:
                    self._rows = await self._read()
                    self._read_at = time.monotonic()
                    self._remember(self._rows)
        return self._rows

    async def _read(self) -> list[dict]:
        try:
            async with self._tab() as session:
                for _ in range(40):  # the app has to load and ask for its inbox
                    await asyncio.sleep(0.5)
                    body = await self._evaluate(session, INBOX_JS)
                    try:
                        rows = json.loads(body).get("threads") or []
                    except (ValueError, AttributeError):
                        continue
                    if rows:
                        log.debug("instagram: %d threads in the inbox", len(rows))
                        return rows
        except Exception as err:
            log.warning("instagram: could not read the inbox: %s", err)
            return []
        log.info("instagram: the inbox came back empty (logged out, or the page did not load)")
        return []

    # A read younger than this already holds whatever the push announced.
    FRESH_SECONDS = 5

    async def _lookup(self, pick, text: str | None) -> Thread | None:
        """The thread `pick` chooses among the rows, read again once when the
        cached rows predate `text`: "Bubble tea ?" then "?" twenty seconds
        later found the first one's preview still cached, so "?" matched no
        thread, went to a chat of its own and was screened as a lone "?"."""
        thread = None
        for refresh in (False, True):
            if refresh and time.monotonic() - self._read_at < self.FRESH_SECONDS:
                break
            for row in await self.inbox(refresh=refresh):
                candidate = pick(row)
                if candidate is not None:
                    thread = candidate
                    break
            if thread is not None and (text is None or any(_same(i.text, text) for i in thread.items)):
                return thread
        return thread

    async def find(self, text: str) -> Thread | None:
        """The thread whose newest message is `text`."""
        def pick(row):
            thread = thread_from_inbox(row, self._tail(row))
            return thread if thread and any(_same(item.text, text) for item in thread.items) else None
        return await self._lookup(pick, text)

    async def thread(self, thread_id: str, text: str | None = None) -> Thread | None:
        """The thread `thread_id`; with `text`, read again when the cached row
        does not have it yet."""
        if not thread_id.isdigit():
            return None

        def pick(row):
            if thread_id in (str(row.get("id")), str(row.get("v2"))):
                return thread_from_inbox(row, self._tail(row))
            return None
        return await self._lookup(pick, text)

    def _tail(self, row: dict) -> list[dict]:
        return self._tails.get(str(row.get("id") or ""), [])

    def _remember(self, rows: list[dict]) -> None:
        moved = False
        for row in rows:
            tid = str(row.get("id") or "")
            text = str(row.get("text") or "").strip()
            at = row.get("at")
            if not tid or not text or not isinstance(at, (int, float)):
                continue
            tail = self._tails.setdefault(tid, [])
            entry = {"text": text, "at": at}
            if entry in tail:
                continue
            tail.append(entry)
            tail.sort(key=lambda e: e["at"])
            del tail[:-self.TAIL]
            moved = True
        if moved:
            self._save_tails()

    def _load_tails(self) -> dict[str, list[dict]]:
        if not self.tails_path:
            return {}
        try:
            with open(self.tails_path) as f:
                loaded = json.load(f)
        except (OSError, ValueError):
            return {}
        if not isinstance(loaded, dict):
            return {}
        return {str(k): [e for e in v if isinstance(e, dict)][-self.TAIL:]
                for k, v in loaded.items() if isinstance(v, list)}

    def _save_tails(self) -> None:
        if not self.tails_path:
            return
        tmp = self.tails_path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(self._tails, f, ensure_ascii=False)
            os.replace(tmp, self.tails_path)
        except OSError as err:
            log.warning("instagram: could not keep the thread tails: %s", err)

    @contextlib.asynccontextmanager
    async def _tab(self, path: str = "/direct/inbox/"):
        """A background tab with direct.js in place, closed however it ends."""
        cdp, target = self.cdp, None
        try:
            target = (await cdp.call("Target.createTarget", {"url": "about:blank", "background": True}))["result"]["targetId"]
            session = (await cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True}))["result"]["sessionId"]
            await cdp.call("Page.enable", {}, session)
            await cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": DIRECT_JS}, session)
            await cdp.call("Page.navigate", {"url": f"{self.origin}{path}"}, session)
            yield session
        finally:
            if target:
                with contextlib.suppress(Exception):
                    await cdp.call("Target.closeTarget", {"targetId": target})

    async def _evaluate(self, session: str, expression: str) -> str:
        answer = await self.cdp.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True,
                                                          "returnByValue": True}, session)
        return answer.get("result", {}).get("result", {}).get("value") or ""

    async def prepare(self) -> None:
        """Whether Instagram can actually push, and turning it on if it is one
        click away. The watcher grants the permission each session
        (`Browser.grantPermissions`); the push subscription is Instagram's own
        to create, from its own control, and it then lives in the profile — so
        a fresh setup only needs that control used once."""
        try:
            async with self._tab() as session:
                await asyncio.sleep(4)
                state = json.loads(await self._evaluate(session, PUSH_JS) or "{}")
                if state.get("subscribed"):
                    log.info("instagram: push notifications are on")
                    return
                control = state.get("control")
                if control:
                    log.info("instagram: turning notifications on (%s)", control)
                    if await self._evaluate(session, CLICK_JS) == "clicked":
                        await asyncio.sleep(3)
                        after = json.loads(await self._evaluate(session, PUSH_JS) or "{}")
                        if after.get("subscribed"):
                            log.info("instagram: push notifications are on")
                            return
                log.warning("instagram: no push subscription, so its notifications never reach Hermes: "
                            "open instagram.com in Hermes' Chrome and turn its notifications on "
                            "(%s here)", state.get("permission", "unknown"))
        except Exception as err:
            log.warning("instagram: could not check push notifications: %s", err)


async def resolve_instagram(instagram: Instagram, pipeline: Pipeline, payload: dict, chat: Chat,
                            message: Message) -> None:
    """The notification's thread, for its sender's name, one chat per thread
    and its history; the notification alone when it cannot be found."""
    try:
        tid = thread_id_of(payload)
        thread = await instagram.thread(tid, message.text) if tid else None
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
    hint = f"your instagram skill, in the thread https://www.instagram.com/direct/t/{thread.id}/"
    pipeline.message(Chat("instagram", thread.id, thread.name, thread.is_group, reply_hint=hint),
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
                        cdp.spawn(instagram.prepare())
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
