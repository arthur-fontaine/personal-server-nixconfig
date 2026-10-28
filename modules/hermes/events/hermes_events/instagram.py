"""Instagram's notifications, from the always-open Chrome in Hermes' session
(modules/hermes/agent/browser.nix), over the DevTools protocol.

Instagram sends Web Push to that Chrome (a Google build: Chrome for Testing
gets a push endpoint that Firebase rejects with 410). The push wakes its
service worker, which calls `showNotification`. Every new target is attached
paused (`Target.setAutoAttach`, `waitForDebuggerOnStart`); a service worker
gets the hook below before Instagram's code runs, then resumes. The hook hands
each notification to a CDP binding, and still shows it.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time

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
      %(binding)s(JSON.stringify({title: String(title || ''), body: String(o.body || ''), tag: String(o.tag || '')}));
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


def hook(host: str = "instagram.com") -> str:
    return HOOK % {"binding": BINDING, "host": host}


def instagram_message(payload: dict, now: float) -> tuple[Chat, Message] | None:
    title, body = payload.get("title", "").strip(), payload.get("body", "").strip()
    if not (title or body):
        return None
    # A DM's notification is titled with the sender (or "Instagram", the
    # sender then leading the body): one chat per sender, so a burst batches.
    who = title if title and title.lower() != "instagram" else body.split(":")[0][:60]
    digest = hashlib.sha256(f"{payload.get('tag', '')}\0{title}\0{body}".encode()).hexdigest()[:16]
    chat = Chat("instagram", who or "instagram", who or "Instagram",
                reply_hint="your instagram skill (https://www.instagram.com/direct/inbox/)")
    return chat, Message(digest, now, who or "Instagram", body or title)


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


async def instagram_watch(pipeline: Pipeline, devtools: str, host: str = "instagram.com",
                          origin: str = ORIGIN) -> None:
    """Stays attached to the browser at `devtools` (http://127.0.0.1:<port>), reconnecting."""
    delay = 5
    while True:
        try:
            async with aiohttp.ClientSession() as http:
                async with http.get(f"{devtools}/json/version") as response:
                    url = (await response.json())["webSocketDebuggerUrl"]
                async with http.ws_connect(url, max_msg_size=0) as ws:
                    cdp = CDP(ws)
                    reader = asyncio.create_task(read(ws, cdp, pipeline, host))
                    await cdp.call("Browser.grantPermissions", {"origin": origin, "permissions": ["notifications"]})
                    await cdp.call("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": True, "flatten": True})
                    log.info("watching Instagram's notifications")
                    delay = 5
                    await reader
        except Exception as err:
            log.warning("browser at %s unavailable: %s", devtools, err)
        await asyncio.sleep(delay)
        delay = min(delay * 2, 300)


async def read(ws, cdp: CDP, pipeline: Pipeline, host: str) -> None:
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
                parsed = instagram_message(json.loads(params.get("payload", "{}")), time.time())
            except ValueError:
                continue
            if parsed:
                pipeline.message(*parsed)
