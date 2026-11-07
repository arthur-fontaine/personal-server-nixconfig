"""The App topic: its slot messages, the requests the app posts there, and
the notifications it is told about (docs/app-protocol.md).

Everything Telegram goes through the gateway's own PTB bot, on the gateway's
event loop; hooks from agent threads hand work over with
run_coroutine_threadsafe. One sender task paces every App-topic message
(≥ 1 s apart, Telegram's per-chat rate) and obeys retry_after.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from . import protocol, speech
from .machine import Machine
from .pet import PetState, animation, mirror
from .questions import Questions
from .status import Status
from .usage import Ledger, estimate_cost

logger = logging.getLogger("app_topic")

TOPIC_NAME = "App"
SLOT_MIN_GAP = 3.0
SEND_GAP = 1.0
STATS_EVERY = 60.0
STATS_REFRESH_GAP = 10.0
EPHEMERAL_FOR = 3600.0
SLOT_MAX_AGE = 47 * 3600.0
SETTLE = 2.5


def owner_id() -> int | None:
    first = os.environ.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()
    return int(first) if first.lstrip("-").isdigit() else None


def _err_text(error: Exception) -> str:
    return str(error).lower()


class App:
    def __init__(self, home: Path, config: dict):
        self.home = Path(home)
        self.config = config
        self.dir = self.home / "app"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.state_path = self.dir / "topic.json"
        self.saved = self._load_state()
        self.adapter = None
        self.app = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.lock = threading.RLock()
        self.questions = Questions(self.changed)
        self.status = Status(self.changed, owner_id)
        self.ledger = Ledger(self.dir / "usage.db", config.get("chain") or [])
        self.machine = Machine(self.dir / "machine.json")
        self.pet = PetState(self.dir)
        self.desired: dict[str, dict] = {}
        self.dirty = threading.Event()
        self.queue: asyncio.Queue | None = None
        self.tasks: list[asyncio.Task] = []
        self.stop = threading.Event()
        self.pending_notify: dict[tuple[int, int], dict] = {}
        self.last_stats = 0.0
        self.extra_handlers: dict[str, Any] = {}  # request type → coroutine fn(req, msg_id) -> data
        self.pet_busy = False
        self.delivery_mtime = 0.0
        self.notify_listeners: list = []  # fn(chat, message_id, text, final) — the call mode
        self.started = False

    # ── persistence ──────────────────────────────────────────────────────

    def _load_state(self) -> dict:
        try:
            data = json.loads(self.state_path.read_text())
        except (OSError, ValueError):
            data = {}
        data.setdefault("thread", None)
        data.setdefault("chat", None)
        data.setdefault("slots", {})
        data.setdefault("ephemeral", [])
        data.setdefault("sprite", {})
        return data

    def save(self) -> None:
        with self.lock:
            tmp = self.state_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.saved, indent=1))
            os.replace(tmp, self.state_path)

    # ── gateway handles ──────────────────────────────────────────────────

    def bot(self):
        adapter, app = self.adapter, self.app
        return getattr(adapter, "_bot", None) or getattr(app, "bot", None)

    def gateway_loop(self):
        ref = getattr(sys.modules.get("gateway.run"), "_gateway_runner_ref", None)
        try:
            runner = ref() if callable(ref) else None
        except Exception:
            runner = None
        loop = getattr(runner, "_gateway_loop", None) or self.loop
        if loop is None or loop.is_closed() or not loop.is_running():
            return None
        return loop

    def submit(self, coro):
        """Run a coroutine on the gateway loop from any thread; a Future, or None."""
        loop = self.gateway_loop()
        if loop is None:
            coro.close()
            return None
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            running = None
        if running is loop:
            return asyncio.ensure_future(coro)
        return asyncio.run_coroutine_threadsafe(coro, loop)

    def attach(self, app, adapter) -> None:
        """The Telegram factory: called at each connect, with a new app and adapter."""
        from telegram.ext import CallbackQueryHandler

        self.app, self.adapter = app, adapter
        try:
            self.loop = asyncio.get_running_loop()
        except RuntimeError:
            pass
        # Its own group: sees every tap, after (and without stopping) Hermes' handlers.
        app.add_handler(CallbackQueryHandler(self.on_callback, block=False), group=7)
        self.wrap(adapter)
        if self.loop is not None:
            self.loop.call_soon(self.start)

    def wrap(self, adapter) -> None:
        if getattr(adapter, "_app_topic_wrapped", False):
            return
        try:
            send, edit, control = adapter.send, adapter.edit_message, adapter._send_control_message
        except AttributeError:
            logger.warning("app_topic: the Telegram adapter changed; no notify or questions")
            return
        plugin = self

        async def wrapped_send(chat_id, content, reply_to=None, metadata=None, *args, **kwargs):
            result = await send(chat_id, content, reply_to, metadata, *args, **kwargs)
            try:
                plugin.on_sent(chat_id, metadata, getattr(result, "message_id", None), content,
                               final=False, ok=getattr(result, "success", False))
            except Exception:
                logger.debug("app_topic: on_sent failed", exc_info=True)
            return result

        async def wrapped_edit(chat_id, message_id, content, *args, finalize=False, metadata=None, **kwargs):
            result = await edit(chat_id, message_id, content, *args, finalize=finalize, metadata=metadata, **kwargs)
            try:
                target = getattr(result, "message_id", None) or message_id
                plugin.on_sent(chat_id, metadata, target, content, final=finalize, ok=getattr(result, "success", False),
                               edited=True)
            except Exception:
                logger.debug("app_topic: on_edit failed", exc_info=True)
            return result

        async def wrapped_control(chat_id, text, *args, reply_markup=None, thread_id=None, metadata=None, **kwargs):
            msg = await control(chat_id, text, *args, reply_markup=reply_markup, thread_id=thread_id,
                                metadata=metadata, **kwargs)
            try:
                plugin.on_card(chat_id, thread_id, getattr(msg, "message_id", None), text, reply_markup)
            except Exception:
                logger.debug("app_topic: on_card failed", exc_info=True)
            return msg

        adapter.send, adapter.edit_message, adapter._send_control_message = wrapped_send, wrapped_edit, wrapped_control
        draft = getattr(adapter, "send_draft", None)
        if draft is not None:
            async def wrapped_draft(chat_id, draft_id, content, metadata=None, *args, **kwargs):
                result = await draft(chat_id, draft_id, content, metadata, *args, **kwargs)
                try:
                    thread = (metadata or {}).get("thread_id") if isinstance(metadata, dict) else None
                    topic = plugin.topic_of(chat_id, thread)
                    if topic is not None and content:
                        for listener in list(plugin.notify_listeners):
                            listener(topic, -int(draft_id or 0), content, False)
                except Exception:
                    logger.debug("app_topic: draft listener failed", exc_info=True)
                return result

            adapter.send_draft = wrapped_draft
        adapter._app_topic_wrapped = True

    # ── chats ────────────────────────────────────────────────────────────

    @staticmethod
    def topic_of(chat_id, thread) -> int | None:
        """0 for the owner's main chat, the topic id in it, None elsewhere."""
        owner = owner_id()
        if owner is None or str(chat_id) != str(owner):
            return None
        thread = str(thread or "")
        if thread in ("", "1", "None"):
            return 0
        try:
            return int(thread)
        except ValueError:
            return None

    def is_app_topic(self, chat_id, thread) -> bool:
        return bool(self.saved.get("thread")) and self.topic_of(chat_id, thread) == self.saved["thread"]

    # ── lifecycle ────────────────────────────────────────────────────────

    def start(self) -> None:
        if self.started:
            self.dirty.set()
            self.submit_coro(self.ensure_topic())
            return
        self.started = True
        self.queue = asyncio.Queue()
        loop = asyncio.get_running_loop()
        self.tasks = [loop.create_task(self.sender()), loop.create_task(self.flusher()), loop.create_task(self.ticker())]
        threading.Thread(target=self.machine.run, args=(self.stop,), daemon=True, name="app_topic-machine").start()
        loop.create_task(self.ensure_topic())

    def submit_coro(self, coro) -> None:
        try:
            asyncio.get_running_loop().create_task(coro)
        except RuntimeError:
            self.submit(coro)

    async def ensure_topic(self) -> int | None:
        owner, bot = owner_id(), self.bot()
        if owner is None or bot is None:
            return None
        if self.saved.get("thread") and self.saved.get("chat") == owner:
            return self.saved["thread"]
        try:
            topic = await bot.create_forum_topic(chat_id=owner, name=TOPIC_NAME)
        except Exception as error:
            logger.warning("app_topic: cannot create the App topic (Threaded Mode on in BotFather?): %s", error)
            return None
        with self.lock:
            self.saved.update(thread=int(topic.message_thread_id), chat=owner, slots={}, sprite={})
            self.save()
        logger.info("app_topic: App topic %s", self.saved["thread"])
        self.dirty.set()
        return self.saved["thread"]

    def changed(self) -> None:
        self.dirty.set()

    # ── sending ──────────────────────────────────────────────────────────

    async def call(self, method: str, **kwargs):
        """One Bot API call through the paced queue; returns its result or raises."""
        if self.queue is None:
            raise RuntimeError("not started")
        future = asyncio.get_running_loop().create_future()
        await self.queue.put((method, kwargs, future))
        return await future

    async def sender(self) -> None:
        last = 0.0
        while True:
            method, kwargs, future = await self.queue.get()
            if future.cancelled():
                continue
            wait = SEND_GAP - (time.monotonic() - last)
            if wait > 0 and method != "delete_message":
                await asyncio.sleep(wait)
            for attempt in range(3):
                bot = self.bot()
                if bot is None:
                    future.set_exception(RuntimeError("Telegram not connected"))
                    break
                try:
                    result = await getattr(bot, method)(**kwargs)
                    future.set_result(result)
                    break
                except Exception as error:
                    retry = getattr(error, "retry_after", None)
                    if retry is not None and attempt < 2:
                        seconds = retry.total_seconds() if hasattr(retry, "total_seconds") else float(retry)
                        await asyncio.sleep(min(60.0, seconds + 0.5))
                        continue
                    if not future.done():
                        future.set_exception(error)
                    break
            last = time.monotonic()

    async def post(self, obj: dict, *, ephemeral: bool = True) -> int | None:
        thread = await self.ensure_topic()
        if thread is None:
            return None
        try:
            msg = await self.call("send_message", chat_id=self.saved["chat"], message_thread_id=thread,
                                  text=protocol.render_html(obj), parse_mode="HTML", disable_notification=True)
        except Exception as error:
            if self._topic_gone(error):
                return None
            logger.info("app_topic: send failed: %s", error)
            return None
        message_id = int(msg.message_id)
        if ephemeral:
            with self.lock:
                self.saved["ephemeral"].append([message_id, time.time() + EPHEMERAL_FOR])
                self.save()
        return message_id

    def _topic_gone(self, error: Exception) -> bool:
        text = _err_text(error)
        if "thread not found" in text or "topic_deleted" in text or "topic not found" in text or "topic_closed" in text:
            logger.warning("app_topic: the App topic is gone; creating a new one")
            with self.lock:
                self.saved.update(thread=None, slots={}, sprite={})
                self.save()
            self.dirty.set()
            return True
        return False

    async def delete(self, message_id: int) -> None:
        try:
            await self.call("delete_message", chat_id=self.saved["chat"], message_id=int(message_id))
        except Exception as error:
            logger.debug("app_topic: delete %s failed: %s", message_id, error)

    # ── slots ────────────────────────────────────────────────────────────

    def build_state(self) -> dict:
        questions = self.questions.public()
        agent = self.status.snapshot(bool(questions))
        slots = {name: s.get("id") for name, s in self.saved["slots"].items() if name != "state"}
        if self.saved["sprite"].get("id"):
            slots["sprite"] = self.saved["sprite"]["id"]
        obj = protocol.message("state", updated_at=protocol.now_iso(), slots=slots, agent=agent,
                               questions=questions, pet=self.pet_public(agent["status"]),
                               subchats=self.subchats())
        return protocol.shrink(obj, [("subchats",), ("questions",)])

    def pet_public(self, status: str) -> dict | None:
        now = time.time()
        with self.pet.lock:
            needs = self.pet.needs
            needs.advance(now, self.status.take_working_seconds())
            for _, failed in self.status.take_finished():
                if not failed:
                    needs.gain(2, now)
                    if needs.burst != "jump":
                        needs.set_burst("wave", now)
            if needs.asleep and status in ("working", "thinking"):
                needs.asleep = False
            self.pet.save()
            slug = self.pet.data["slug"]
            if not slug:
                return None
            manifest_path = self.dir / "pet" / "pet.json"
            try:
                manifest = json.loads(manifest_path.read_text())
            except (OSError, ValueError):
                manifest = None
            name = (manifest or {}).get("displayName") or slug
            return {"id": slug, "name": name, "version": self.pet.data["version"], "manifest": manifest,
                    "sprite_message_id": self.saved["sprite"].get("id"),
                    "animation": animation(needs, status, now), "mood": needs.mood(status in ("working", "thinking")),
                    **needs.public(), "updated_at": protocol.now_iso(needs.updated)}

    def subchats(self) -> list[dict]:
        state = sys.__dict__.get("_hermes_unii_state") or {}
        runtime = state.get("runtime")
        owner = owner_id()
        if runtime is None or owner is None:
            return []
        out = []
        try:
            policies = runtime.policies
            with policies._lock:
                records = dict(policies._chats)
            for key, record in records.items():
                parts = key.split(":")
                if len(parts) != 4 or parts[0] != "telegram" or parts[1] != "dm" or parts[2] != str(owner):
                    continue
                try:
                    topic = int(parts[3])
                except ValueError:
                    continue
                if topic == self.saved.get("thread"):
                    continue
                chat = _unii_chat(runtime, key)
                policy, own, _ = runtime.chat_volumes(chat)
                encrypted = bool(runtime.encrypted(own, policy))
                expires = None
                try:
                    from importlib import import_module

                    seconds = import_module(type(runtime.policies).__module__).ttl_seconds(policy.ttl)
                    if seconds and record.last_active:
                        expires = protocol.now_iso(record.last_active + seconds)
                except Exception:
                    pass
                out.append({"topic_id": topic, "name": getattr(record, "name", "") or None,
                            "preset": record.preset if not record.overrides else None,
                            "encrypted": encrypted, "unlocked": encrypted and not runtime.is_locked(own, policy),
                            "ttl": policy.ttl, "expires_at": expires})
        except Exception:
            logger.debug("app_topic: sub-chats unreadable", exc_info=True)
        return sorted(out, key=lambda s: s["topic_id"])

    def build_stats(self) -> dict:
        obj = protocol.message("stats", updated_at=protocol.now_iso(), machine=self.machine.snapshot(),
                               models=self.ledger.summary())
        return protocol.shrink(obj, [("models",)])

    def build_devices(self) -> dict:
        path = self.dir / "delivery.json"
        try:
            delivery = json.loads(path.read_text())
            self.delivery_mtime = path.stat().st_mtime
        except (OSError, ValueError):
            delivery = None
        obj = protocol.message("devices", updated_at=protocol.now_iso(), delivery=delivery)
        return protocol.shrink(obj, [("delivery", "devices")])

    async def flusher(self) -> None:
        """Edit each slot when it changed, at most once per SLOT_MIN_GAP."""
        while True:
            await asyncio.to_thread(self.dirty.wait, 1.0)
            self.dirty.clear()
            try:
                await self.flush()
            except Exception:
                logger.warning("app_topic: flush failed", exc_info=True)

    async def flush(self) -> None:
        if await self.ensure_topic() is None:
            return
        now = time.time()
        if "stats" not in self.desired or now - self.last_stats >= STATS_EVERY:
            self.desired["stats"] = await asyncio.to_thread(self.build_stats)
            self.last_stats = now
        path = self.dir / "delivery.json"
        mtime = path.stat().st_mtime if path.exists() else 0.0
        if "devices" not in self.desired or mtime != self.delivery_mtime:
            self.desired["devices"] = self.build_devices()
        await self.sync_sprite()
        # state last: it names the other slots' ids.
        for name in ("stats", "devices"):
            await self.put_slot(name, self.desired[name])
        self.desired["state"] = await asyncio.to_thread(self.build_state)
        if not await self.put_slot("state", self.desired["state"]):
            self.dirty.set()
        activity = self.extra_handlers.get("_push_activity")
        if activity is not None:
            state = self.desired["state"]
            question = (state.get("questions") or [None])[0]
            signature = (state["agent"]["status"], state["agent"]["task"], question and question["id"])
            if signature != getattr(self, "_activity_sig", None):
                self._activity_sig = signature
                try:
                    await activity(state["agent"], question)
                except Exception:
                    logger.debug("app_topic: activity push failed", exc_info=True)

    async def put_slot(self, name: str, obj: dict) -> bool:
        """Send or edit one slot; False when it must wait (rate) or failed."""
        slot = self.saved["slots"].get(name) or {}
        body = protocol.dumps({k: v for k, v in obj.items() if k != "updated_at"})
        if slot.get("body") == body and time.time() - slot.get("sent", 0) < SLOT_MAX_AGE:
            return True
        if time.time() - slot.get("edited", 0) < SLOT_MIN_GAP:
            return False
        text = protocol.render_html(obj)
        message_id = slot.get("id")
        if message_id and time.time() - slot.get("sent", 0) < SLOT_MAX_AGE:
            try:
                await self.call("edit_message_text", chat_id=self.saved["chat"], message_id=message_id,
                                text=text, parse_mode="HTML")
                self._slot_saved(name, message_id, body, sent=slot.get("sent"))
                return True
            except Exception as error:
                if "not modified" in _err_text(error):
                    self._slot_saved(name, message_id, body, sent=slot.get("sent"))
                    return True
                if self._topic_gone(error):
                    return False
                logger.info("app_topic: slot %s edit failed (%s): posting a new one", name, error)
        new_id = await self.post(obj, ephemeral=False)
        if new_id is None:
            return False
        if message_id:
            await self.delete(message_id)
        self._slot_saved(name, new_id, body, sent=time.time())
        return True

    def _slot_saved(self, name: str, message_id: int, body: str, sent: float | None) -> None:
        with self.lock:
            self.saved["slots"][name] = {"id": message_id, "body": body, "sent": sent or time.time(),
                                         "edited": time.time()}
            self.save()

    async def sync_sprite(self) -> None:
        """The spritesheet as a document in the App topic, once per pet version."""
        version = self.pet.data["version"]
        sheet = self.dir / "pet" / "spritesheet.webp"
        sprite = self.saved["sprite"]
        if not self.pet.data["slug"] or not sheet.exists():
            return
        fresh = time.time() - sprite.get("sent", 0) < SLOT_MAX_AGE
        if sprite.get("version") == version and sprite.get("id") and fresh:
            return
        try:
            with open(sheet, "rb") as f:
                msg = await self.call("send_document", chat_id=self.saved["chat"],
                                      message_thread_id=self.saved["thread"], document=f,
                                      filename=f"{self.pet.data['slug']}-v{version}.webp",
                                      caption=protocol.dumps(protocol.message("sprite", version=version)),
                                      disable_notification=True)
        except Exception as error:
            self._topic_gone(error)
            logger.info("app_topic: sprite not sent: %s", error)
            return
        old = sprite.get("id")
        with self.lock:
            self.saved["sprite"] = {"id": int(msg.message_id), "version": version, "sent": time.time()}
            self.save()
        if old:
            await self.delete(old)

    async def ticker(self) -> None:
        """Housekeeping every few seconds: settled notifications, expired
        ephemeral messages, the stats minute."""
        while True:
            await asyncio.sleep(1.0)
            try:
                await self.flush_notify()
                now = time.time()
                with self.lock:
                    due = [e for e in self.saved["ephemeral"] if e[1] <= now]
                    if due:
                        self.saved["ephemeral"] = [e for e in self.saved["ephemeral"] if e[1] > now]
                        self.save()
                for message_id, _ in due:
                    await self.delete(message_id)
                if now - self.last_stats >= STATS_EVERY:
                    self.dirty.set()
                    # A pet installed or chosen outside the plugin (hermes pets…).
                    await asyncio.to_thread(self.sync_pet)
            except Exception:
                logger.debug("app_topic: tick failed", exc_info=True)

    # ── notifications ────────────────────────────────────────────────────

    def on_sent(self, chat_id, metadata, message_id, content, *, final: bool, ok: bool, edited: bool = False) -> None:
        if not ok or not message_id or not content:
            return
        thread = (metadata or {}).get("thread_id") if isinstance(metadata, dict) else None
        topic = self.topic_of(chat_id, thread)
        if topic is None or self.is_app_topic(chat_id, thread):
            return
        for listener in list(self.notify_listeners):
            try:
                listener(topic, int(message_id), content, final or not edited)
            except Exception:
                logger.debug("app_topic: listener failed", exc_info=True)
        key = (topic, int(message_id))
        with self.lock:
            entry = self.pending_notify.get(key)
            if entry is None:
                # Telegram notified once, at the first send: a later edit is not a new notification.
                if int(message_id) in self.saved.get("notified", []):
                    return
                entry = {"chat": topic, "message_id": int(message_id)}
                self.pending_notify[key] = entry
            entry.update(text=content, at=time.time(), final=entry.get("final", False) or final)

    async def flush_notify(self) -> None:
        now = time.time()
        with self.lock:
            ready = [k for k, e in self.pending_notify.items() if e.get("final") or now - e["at"] >= SETTLE]
            entries = [self.pending_notify.pop(k) for k in ready]
            if entries:
                notified = self.saved.setdefault("notified", [])
                fresh = [e for e in entries if e["message_id"] not in notified]
                notified.extend(e["message_id"] for e in fresh)
                del notified[:-200]
                entries = fresh
        for entry in entries:
            text = entry["text"]
            if not speech.plain(speech.split_override(text)[0]).strip():
                continue
            await self.notify(entry["chat"], entry["message_id"], "message", speech.body(text), speech.spoken(text))

    async def notify(self, chat: int, message_id: int | None, kind: str, body: str, spoken: str,
                     interruption: str | None = None) -> None:
        title = "Hermes"
        if chat:
            name = next((s["name"] for s in self.subchats() if s["topic_id"] == chat and s["name"]), None)
            title = f"Hermes · {name}" if name else title
        obj = protocol.message("notify", chat=chat, message_id=message_id, kind=kind,
                               interruption=interruption or ("time-sensitive" if kind in ("question", "approval")
                                                             else "active"),
                               title=title, body=body, spoken=spoken)
        await self.post(obj)
        push = self.extra_handlers.get("_push_notify")
        if push is not None:
            try:
                await push(obj)
            except Exception:
                logger.debug("app_topic: push failed", exc_info=True)

    # ── questions ────────────────────────────────────────────────────────

    def on_card(self, chat_id, thread, message_id, text, markup, command=None, summary=None) -> None:
        topic = self.topic_of(chat_id, thread)
        if topic is None or message_id is None:
            return
        item = self.questions.from_card(chat=topic, message_id=int(message_id), text_html=text, markup=markup,
                                        command=command, summary=summary)
        if item is None:
            return
        with self.lock:
            notified = self.saved.setdefault("notified", [])
            notified.append(int(message_id))
            del notified[:-200]
        kind = "approval" if item["kind"] == "approval" else "question"
        self.submit_coro(self.notify(topic, int(message_id), kind, protocol.cut(item["text"], 240) or "", item["spoken"]))

    async def on_callback(self, update, context=None) -> None:
        query = getattr(update, "callback_query", None)
        data = str(getattr(query, "data", None) or "")
        if data and getattr(getattr(query, "from_user", None), "id", None) == owner_id():
            if self.questions.resolve_callback(data):
                with self.pet.lock:
                    self.pet.needs.gain(5, time.time())

    def human_input_resolved(self, kind: str = "", session_key: str = "", outcome: str = "", **_) -> None:
        if kind not in ("approval", "clarify"):
            return
        chat = None
        parts = (session_key or "").split(":")
        if len(parts) >= 5 and parts[2] == "telegram":
            chat = self.topic_of(parts[4], parts[5] if len(parts) > 5 else "")
        if outcome == "submitted" or outcome in ("once", "session", "always", "deny", "timeout", "cancelled",
                                                  "timed_out", "terminated", "undelivered", "error"):
            self.questions.resolve(kind=kind, chat=chat)

    # ── requests ─────────────────────────────────────────────────────────

    def dispatch(self, event) -> dict | None:
        """pre_gateway_dispatch: a message in the App topic never becomes a turn."""
        source = getattr(event, "source", None)
        platform = getattr(getattr(source, "platform", None), "value", getattr(source, "platform", None))
        if platform != "telegram" or not self.is_app_topic(getattr(source, "chat_id", None),
                                                          getattr(source, "thread_id", None)):
            return None
        if str(getattr(source, "user_id", "")) != str(owner_id()):
            return {"action": "skip", "reason": "app-topic: not the owner"}
        text = getattr(event, "text", None) or ""
        message_id = getattr(event, "message_id", None) or getattr(source, "message_id", None)
        self.submit(self.handle(text, int(message_id) if message_id else None))
        return {"action": "skip", "reason": "app-topic"}

    async def handle(self, text: str, message_id: int | None) -> None:
        request = protocol.parse(text)
        if request is None:
            # Not ours (someone typing in the topic): leave it, say nothing.
            return
        kind = request.get("type", "")
        try:
            data = await self.answer(kind, request, message_id)
            reply = None if data is _NO_REPLY else protocol.message("reply", re=message_id, ok=True, data=data or {})
        except RequestError as error:
            reply = protocol.message("reply", re=message_id, ok=False,
                                     error={"code": error.code, "message": str(error)})
        except Exception as error:
            logger.warning("app_topic: request %s failed", kind, exc_info=True)
            reply = protocol.message("reply", re=message_id, ok=False, error={"code": "failed", "message": str(error)})
        if reply is not None:
            await self.post(reply)
        if message_id:
            await self.delete(message_id)

    async def answer(self, kind: str, request: dict, message_id: int | None):
        if kind == "hello":
            with self.lock:
                self.saved["app"] = {k: request.get(k) for k in
                                     ("app_version", "build", "device", "device_id", "pet_version")}
                self.saved["app"]["at"] = protocol.now_iso()
                self.save()
            for slot in self.saved["slots"].values():
                slot["edited"] = 0
            self.dirty.set()
            return {"server_version": self.config.get("server_version", "1"), "protocol": protocol.VERSION}
        if kind == "stats.refresh":
            # At most one refresh per STATS_REFRESH_GAP: a later one waits for its turn.
            due = max(time.time(), getattr(self, "last_refresh", 0.0) + STATS_REFRESH_GAP)
            self.last_refresh = due
            self.last_stats = min(self.last_stats, due - STATS_EVERY)
            self.dirty.set()
            return {}
        if kind in ("pet.feed", "pet.play", "pet.sleep", "pet.wake"):
            with self.pet.lock:
                if not self.pet.data["slug"]:
                    raise RequestError("unavailable", "no pet yet: ask Hermes for one, or send pet.generate")
                now = time.time()
                self.pet.needs.advance(now, self.status.take_working_seconds())
                refused = self.pet.needs.act(kind.split(".", 1)[1], now)
                self.pet.save()
                if refused:
                    raise RequestError("bad_request", refused)
                data = self.pet.needs.public()
            self.dirty.set()
            return data
        if kind == "pet.generate":
            prompt = str(request.get("prompt") or "").strip()
            if not prompt:
                raise RequestError("bad_request", "prompt is required")
            started = self.start_pet_generation(prompt, request.get("name"))
            return {"started": started}
        if kind == "app.reinstall":
            return await asyncio.to_thread(self.reinstall, request.get("devices") or [])
        if kind == "ack":
            ids = [int(i) for i in request.get("ids") or [] if str(i).isdigit()]
            mine = {e[0] for e in self.saved["ephemeral"]}
            for i in ids:
                if i in mine:
                    await self.delete(i)
            with self.lock:
                self.saved["ephemeral"] = [e for e in self.saved["ephemeral"] if e[0] not in ids]
                self.save()
            return _NO_REPLY
        handler = self.extra_handlers.get(kind)
        if handler is not None:
            return await handler(request, message_id)
        if kind in ("call.start", "push.register", "push.unregister"):
            raise RequestError("unavailable", f"{kind} is off on this server")
        raise RequestError("unknown_type", f"unknown request type {kind!r}")

    def reinstall(self, devices: list) -> dict:
        cli = self.config.get("delivery_cli") or "hermes-app"
        args = [cli, "install", "--reason", "app request"]
        for device in devices:
            args += ["--device", str(device)]
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=60)
        except FileNotFoundError:
            raise RequestError("unavailable", "app delivery is not set up on this server") from None
        if out.returncode != 0:
            raise RequestError("failed", (out.stderr or out.stdout).strip()[-300:] or f"exit {out.returncode}")
        try:
            return json.loads(out.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return {"started": True}

    # ── usage hooks ──────────────────────────────────────────────────────

    def post_api_request(self, provider: str = "", model: str = "", base_url: str = "", usage=None,
                         response_model=None, **kwargs) -> None:
        cost = estimate_cost(model, provider, base_url, usage)
        self.ledger.record(provider, model, usage=usage, cost=cost)

    def api_request_error(self, provider: str = "", model: str = "", **kwargs) -> None:
        self.ledger.record(provider, model, error=True)

    def post_auxiliary_call(self, provider: str = "", model: str = "", base_url: str = "", usage=None,
                            error=None, **kwargs) -> None:
        if error is not None:
            self.ledger.record(provider, model, aux=True, error=True)
            return
        self.ledger.record(provider, model, aux=True, usage=usage, cost=estimate_cost(model, provider, base_url, usage))

    # ── pets ─────────────────────────────────────────────────────────────

    def sync_pet(self) -> dict | None:
        """Adopt Hermes' active pet if it changed, and mirror it for the build."""
        try:
            from agent.pet import store

            slug = ""
            try:
                from hermes_cli.config import load_config

                slug = ((load_config() or {}).get("display", {}) or {}).get("pet", {}).get("slug", "") or ""
            except Exception:
                pass
            pet = store.resolve_active_pet(slug or None) if slug else None
            if pet is None:
                generated = [p for p in store.installed_pets() if getattr(p, "generated", False)]
                pet = max(generated, key=lambda p: p.spritesheet.stat().st_mtime) if generated else None
        except Exception:
            logger.debug("app_topic: no pet store", exc_info=True)
            return None
        if pet is None:
            return None
        return self.adopt_pet(pet.slug, pet.directory)

    def adopt_pet(self, slug: str, directory: Path) -> dict:
        changed = slug != self.pet.data["slug"]
        version = self.pet.adopt(slug)
        out = self.dir / "pet"
        manifest_path = out / "pet.json"
        current = None
        try:
            current = json.loads(manifest_path.read_text())
        except (OSError, ValueError):
            pass
        if changed or not current or current.get("version") != version or current.get("id") != slug:
            current = mirror(Path(directory), slug, version, out)
        self.dirty.set()
        return current

    def start_pet_generation(self, prompt: str, name=None, on_done=None) -> bool:
        with self.lock:
            if self.pet_busy:
                raise RequestError("busy", "a pet is already being generated")
            self.pet_busy = True

        def run():
            try:
                result = generate_pet(prompt, name)
                manifest = self.adopt_pet(result["slug"], Path(result["directory"]))
                message = f"Your new pet {manifest['displayName']} has hatched."
                outcome = {"ok": True, "pet": manifest}
            except Exception as error:
                logger.warning("app_topic: pet generation failed: %s", error)
                message = f"The new pet could not be generated: {error}"
                outcome = {"ok": False, "error": str(error)}
            finally:
                with self.lock:
                    self.pet_busy = False
            self.submit(self.notify(0, None, "message", message, speech.spoken(message)))
            if on_done is not None:
                on_done(outcome)

        threading.Thread(target=run, daemon=True, name="app_topic-pet").start()
        return True


class RequestError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


_NO_REPLY = object()


def _unii_chat(runtime, key: str):
    policy_module = sys.modules.get(type(runtime.policies).__module__)
    return policy_module.Chat.from_key(key)


def generate_pet(prompt: str, name=None) -> dict:
    """Hermes' own hatch: one base look, then one row per animation state,
    packed into the Codex atlas and saved to ~/.hermes/pets/<slug>/, then
    made the active pet."""
    from agent.pet import store
    from agent.pet.generate import orchestrate
    from agent.pet.generate.imagegen import GenerationError

    drafts = orchestrate.generate_base_drafts(prompt, n=1)
    if not drafts:
        raise GenerationError("the image provider returned no base look")
    display = (str(name).strip() if name else "") or _name_from(prompt)
    slug = store.unique_slug(display)
    result = orchestrate.hatch_pet(base_image=drafts[0], slug=slug, display_name=display, description=prompt,
                                   concept=prompt)
    try:
        from hermes_cli.config import load_config, save_config

        config = load_config() or {}
        pet = config.setdefault("display", {}).setdefault("pet", {})
        pet.update(slug=result.slug, enabled=True)
        save_config(config)
    except Exception:
        # Managed mode refuses config edits: the plugin follows the newest generated pet instead.
        logger.debug("app_topic: could not select the pet in config.yaml", exc_info=True)
    pet = store.load_pet(result.slug)
    return {"slug": result.slug, "directory": str(pet.directory if pet else store.pets_dir() / result.slug)}


def _name_from(prompt: str) -> str:
    words = [w for w in prompt.replace(",", " ").split() if w.isalpha()][:2]
    return " ".join(w.capitalize() for w in words) or "Pet"
