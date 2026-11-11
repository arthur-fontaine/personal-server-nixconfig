"""The App topic: its slot messages, the requests the app posts there, and
the notifications it is told about (docs/app-protocol.md).

Everything Telegram goes through the gateway's own PTB bot, on the gateway's
event loop; hooks from agent threads hand work over with
run_coroutine_threadsafe. One sender task paces every App-topic message
(≥ 1 s apart, Telegram's per-chat rate) and obeys retry_after.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from . import memory, protocol, speech, ui
from .hatch import HatchFailed, ProviderRefused, plain_refusal, refusal  # noqa: F401  (callers import them from here)
from .machine import Machine
from .pet import PetState, animation, mirror, mood
from .pending import Pending
from .questions import Questions
from .status import Status
from .usage import Ledger, estimate_cost

logger = logging.getLogger("app_topic")

TOPIC_NAME = "App"
# On the owner's message a running turn has yet to take in (pending.py).
PENDING_REACTION = "\U0001f440"
SLOT_MIN_GAP = 3.0
SEND_GAP = 1.0
STATS_EVERY = 60.0
STATS_REFRESH_GAP = 10.0
EPHEMERAL_FOR = 3600.0
SLOT_MAX_AGE = 47 * 3600.0
SETTLE = 2.5
CALL_MAX = 2 * 3600.0
# Dynamic UIs remembered (their App-topic message and spec), and re-posted into a new App topic.
UI_KEPT = 300
UI_REPOST = 30
UI_STAGED_FOR = 900.0  # a render_ui whose reply never came is dropped


def owner_id() -> int | None:
    first = os.environ.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()
    return int(first) if first.lstrip("-").isdigit() else None


def _err_text(error: Exception) -> str:
    return str(error).lower()



def notify_title(subchats: list[dict], chat: int | None) -> tuple[str, bool]:
    """A notification's title, and whether its chat is private.

    A private (encrypted) sub-chat's name never leaves the chat: the lock screen, the
    notification centre and an APNs push read "Hermes", and the app labels it "Private chat" in
    the owner's language from the `private` flag. Other sub-chats are "Hermes · <name>".
    """
    sub = next((s for s in subchats if chat and s["topic_id"] == chat), None)
    if sub is None:
        return "Hermes", False
    if sub.get("encrypted"):
        return "Hermes", True
    return (f"Hermes · {sub['name']}" if sub.get("name") else "Hermes"), False

def is_private(subchats: list[dict], chat: int | None) -> bool:
    return any(chat and s["topic_id"] == chat and s.get("encrypted") for s in subchats)


def private_notification(kind: str) -> tuple[str, str]:
    """A private sub-chat's notification body and spoken text (design-rules 1.4b): nothing of the
    content leaves the app — lock screen, banners, AirPods and Siri announcements, pushes. The app
    shows them in the owner's language from the `private` flag."""
    if kind in ("question", "approval"):
        return "Hermes needs you", "Hermes needs your answer."
    return "New message", "New message from Hermes."


def activity_redacted(subchats: list[dict], agent: dict, question: dict | None) -> tuple[dict, dict | None]:
    """The Live Activity's content without a private sub-chat's content: no task, no question
    text or summary, and only approval buttons (their labels are the standard ones; a clarify's
    choices are content: answered in the app)."""
    if is_private(subchats, agent.get("chat")):
        agent = {**agent, "task": None}
    if question and is_private(subchats, question.get("chat")):
        question = {**question, "text": "", "summary": None, "command": None, "spoken": None,
                    "options": question.get("options") if question.get("kind") == "approval" else []}
    return agent, question


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
        self.pending = Pending(self.changed)
        self.ledger = Ledger(self.dir / "usage.db", config.get("chain") or [])
        self.machine = Machine(self.dir / "machine.json")
        self.pet = PetState(self.dir)
        self.desired: dict[str, dict] = {}
        self.dirty = threading.Event()
        self.queue: asyncio.Queue | None = None
        self.tasks: list[asyncio.Task] = []
        self.stop = threading.Event()
        self.pending_notify: dict[tuple[int, int], dict] = {}
        self.details_sent: list = []  # (chat, message id) of replies whose detail went out
        self.staged_ui: dict[int, tuple[dict, float]] = {}  # topic → (spec, when): render_ui's, for the reply
        self.last_stats = 0.0
        self.extra_handlers: dict[str, Any] = {}  # request type → coroutine fn(req, msg_id) -> data
        self.pet_busy = False
        self.delivery_mtime = 0.0
        self.started = False
        self.call_until = 0.0
        self.last_models: dict[str, dict] = {}

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
        data.setdefault("ui", [])
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

        def silent(metadata) -> bool:
            # Hermes' own rule ("important" mode: only what it flags notifies), so
            # the app announces what Telegram itself would ring for.
            try:
                return bool(adapter._notification_kwargs(metadata if isinstance(metadata, dict) else None))
            except Exception:
                return False

        async def send_detail(chat_id, detail, metadata, key) -> None:
            """A reply's written detail, once, as its own message after it."""
            if not detail or key in plugin.details_sent:
                return
            plugin.details_sent.append(key)
            del plugin.details_sent[:-200]
            await wrapped_send(chat_id, detail, None, metadata)

        async def wrapped_send(chat_id, content, reply_to=None, metadata=None, *args, **kwargs):
            # Only the owner's DM: other chats get what Hermes wrote.
            detail = None
            if isinstance(content, str) and plugin.topic_of(chat_id, (metadata or {}).get("thread_id")
                                                            if isinstance(metadata, dict) else None) is not None:
                content, detail = speech.outgoing(content)
                if not content.strip() and detail:
                    content, detail = detail, None
            result = await send(chat_id, content, reply_to, metadata, *args, **kwargs)
            try:
                plugin.on_sent(chat_id, metadata, getattr(result, "message_id", None), content,
                               final=False, ok=getattr(result, "success", False), silent=silent(metadata))
            except Exception:
                logger.debug("app_topic: on_sent failed", exc_info=True)
            await plugin.attach_ui(chat_id, metadata, result, content)
            if detail and getattr(result, "success", False):
                await send_detail(chat_id, detail, metadata, (str(chat_id), getattr(result, "message_id", None)))
            return result

        async def wrapped_edit(chat_id, message_id, content, *args, finalize=False, metadata=None, **kwargs):
            detail = None
            if isinstance(content, str) and plugin.topic_of(chat_id, (metadata or {}).get("thread_id")
                                                            if isinstance(metadata, dict) else None) is not None:
                # A streaming edit stops at the detail line; the final one sends it apart.
                content, detail = speech.outgoing(content)
            result = await edit(chat_id, message_id, content, *args, finalize=finalize, metadata=metadata, **kwargs)
            try:
                target = getattr(result, "message_id", None) or message_id
                plugin.on_sent(chat_id, metadata, target, content, final=finalize, ok=getattr(result, "success", False),
                               edited=True, silent=not finalize or silent(metadata))
            except Exception:
                logger.debug("app_topic: on_edit failed", exc_info=True)
            if finalize:
                await plugin.attach_ui(chat_id, metadata, result, content, message_id)
            if detail and finalize and getattr(result, "success", False):
                await send_detail(chat_id, detail, metadata, (str(chat_id), message_id))
            return result

        async def wrapped_control(chat_id, text, *args, reply_markup=None, thread_id=None, metadata=None, **kwargs):
            msg = await control(chat_id, text, *args, reply_markup=reply_markup, thread_id=thread_id,
                                metadata=metadata, **kwargs)
            try:
                # Where Telegram put it: the adapter retries without the topic when
                # it is gone (_send_message_with_thread_fallback).
                thread = thread_id
                if hasattr(msg, "is_topic_message"):
                    thread = getattr(msg, "message_thread_id", None) if msg.is_topic_message else None
                plugin.on_card(chat_id, thread, getattr(msg, "message_id", None), text, reply_markup)
            except Exception:
                logger.debug("app_topic: on_card failed", exc_info=True)
            return msg

        adapter.send, adapter.edit_message, adapter._send_control_message = wrapped_send, wrapped_edit, wrapped_control
        draft = getattr(adapter, "send_draft", None)
        if draft is not None:
            async def wrapped_draft(chat_id, draft_id, content, metadata=None, *args, **kwargs):
                # The main chat streams as native drafts: they stop at the detail line too.
                if isinstance(content, str) and plugin.topic_of(chat_id, (metadata or {}).get("thread_id")
                                                                if isinstance(metadata, dict) else None) is not None:
                    content = speech.outgoing(content)[0]
                return await draft(chat_id, draft_id, content, metadata, *args, **kwargs)

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
        if self.saved["ui"]:
            asyncio.get_running_loop().create_task(self.repost_ui())
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

    # ── dynamic UI (§8) ──────────────────────────────────────────────────

    def stage_ui(self, topic: int, spec: dict) -> None:
        """render_ui: the spec waits for the turn's next message in that chat (its reply)."""
        with self.lock:
            self.staged_ui[topic] = (spec, time.time())

    async def attach_ui(self, chat_id, metadata, result, content, message_id=None) -> None:
        """A message Hermes sent: the UI render_ui staged in its chat, if any, goes with it."""
        try:
            if not getattr(result, "success", False) or not isinstance(content, str) or not content.strip():
                return
            thread = metadata.get("thread_id") if isinstance(metadata, dict) else None
            topic = self.topic_of(chat_id, thread)
            if topic is None or self.is_app_topic(chat_id, thread):
                return
            with self.lock:
                staged = self.staged_ui.pop(topic, None)
            if staged is None or time.time() - staged[1] > UI_STAGED_FOR:
                return
            target = getattr(result, "message_id", None) or message_id
            await self.post_ui(topic, int(target), staged[0], key=ui.key(content))
        except Exception:
            logger.warning("app_topic: the UI was not attached", exc_info=True)

    async def post_ui(self, chat: int, message_id: int, spec: dict, *, key: str = "",
                      remember: bool = True) -> int | None:
        """The `ui` envelope in the App topic: inline when it fits a message, else the spec as a
        ui.json document under the envelope without it. Kept (no expiry): the app finds it again
        in the topic's history."""
        obj = protocol.message("ui", chat=chat, message_id=message_id, key=key, spec=spec)
        as_file = not protocol.fits(obj)
        if not as_file:
            app_id = await self.post(obj, ephemeral=False)
        else:
            thread = await self.ensure_topic()
            if thread is None:
                return None
            caption = protocol.message("ui", chat=chat, message_id=message_id, key=key, file=True)
            try:
                msg = await self.call("send_document", chat_id=self.saved["chat"], message_thread_id=thread,
                                      document=io.BytesIO(protocol.dumps(spec).encode()), filename="ui.json",
                                      caption=protocol.dumps(caption), disable_notification=True)
                app_id = int(msg.message_id)
            except Exception as error:
                self._topic_gone(error)
                logger.info("app_topic: ui document not sent: %s", error)
                app_id = None
        if remember:
            self._remember_ui(chat, message_id, spec, app_id, as_file, key)
        return app_id

    def _ui_path(self, chat: int, message_id: int) -> Path:
        return self.dir / "ui" / f"{chat}_{message_id}.json"

    def _remember_ui(self, chat: int, message_id: int, spec: dict, app_id: int | None, as_file: bool,
                     key: str = "") -> None:
        """(chat, message) → its App-topic message, and the spec on disk, so a new App topic
        (after a restart that lost it) gets them again."""
        path = self._ui_path(chat, message_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(protocol.dumps(spec))
        with self.lock:
            entries = [e for e in self.saved["ui"] if (e["chat"], e["message_id"]) != (chat, message_id)]
            entries.append({"chat": chat, "message_id": message_id, "id": app_id, "file": as_file, "key": key})
            dropped, self.saved["ui"] = entries[:-UI_KEPT], entries[-UI_KEPT:]
            self.save()
        for e in dropped:
            self._ui_path(e["chat"], e["message_id"]).unlink(missing_ok=True)

    async def repost_ui(self) -> None:
        """A new App topic starts empty: the latest UIs go there again, oldest first."""
        for entry in list(self.saved["ui"])[-UI_REPOST:]:
            try:
                spec = json.loads(self._ui_path(entry["chat"], entry["message_id"]).read_text())
            except (OSError, ValueError):
                continue
            await self.post_ui(entry["chat"], entry["message_id"], spec, key=entry.get("key", ""))

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
                               questions=questions, pending=self.pending.public(),
                               pet=self.pet_public(agent["status"]), subchats=self.subchats())
        return protocol.shrink(obj, [("subchats",), ("questions",)])

    def pet_public(self, status: str) -> dict | None:
        now = time.time()
        with self.pet.lock:
            outcomes = [outcome for _, outcome in self.status.take_finished() if outcome != "interrupted"]
            if outcomes:
                # The last turn to end sets the beat; a stopped one gets none.
                self.pet.react("happy" if outcomes[-1] == "done" else "confused", now)
            slug = self.pet.data["slug"]
            if not slug:
                return None
            manifest_path = self.dir / "pet" / "pet.json"
            try:
                manifest = json.loads(manifest_path.read_text())
            except (OSError, ValueError):
                manifest = None
            name = (manifest or {}).get("displayName") or slug
            beat = (self.pet.beat, self.pet.beat_until, now)
            current = mood(status, *beat)
            return {"id": slug, "name": name, "version": self.pet.data["version"], "manifest": manifest,
                    "sprite_message_id": self.saved["sprite"].get("id"),
                    "mood": current, "animation": animation(status, *beat),
                    "mood_until": protocol.now_iso(self.pet.beat_until) if current in ("happy", "confused") else None}

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

    def build_controls(self) -> dict:
        """Current values of what the app sets natively, and how to set them."""
        owner = owner_id()
        chain = list(self.config.get("chain") or [])
        models = [{**c, "role": "main" if i == 0 else "fallback"} for i, c in enumerate(chain)]
        if self.config.get("local_model"):
            models.append({"provider": "uzu", "model": "local", "role": "local"})
        current = {}
        overrides = {}
        ref = getattr(sys.modules.get("gateway.run"), "_gateway_runner_ref", None)
        try:
            runner = ref() if callable(ref) else None
            overrides = dict(getattr(runner, "_session_model_overrides", None) or {})
        except Exception:
            overrides = {}
        for key, value in overrides.items():
            parts = str(key).split(":")
            if len(parts) >= 5 and parts[2] == "telegram":
                chat = self.topic_of(parts[4], parts[5] if len(parts) > 5 else "")
                if chat is not None and isinstance(value, dict):
                    current[str(chat)] = {"provider": value.get("provider"), "model": value.get("model")}
        with self.lock:
            last = dict(self.last_models)
        mode = self.permission_mode()
        return protocol.message(
            "controls", updated_at=protocol.now_iso(),
            permission_mode=mode,
            model={"chain": models, "default": models[0] if models else None, "current": current, "last": last,
                   "set_main": "/model {model} --provider {provider}",
                   "set_subchat": "/sub set model {provider}:{model}"},
            presets=self.config.get("presets") or [],
            commands=[c for c in COMMANDS if c["id"] != "permissions" or mode is not None],
            owner=owner)

    def permission_mode(self) -> dict | None:
        """guard's permission mode (hermes-tweaks' auto mode): its current
        value, persisted by guard in ~/.hermes/guard/mode.json, set with
        `/mode <value>`. None without it."""
        guard = sys.modules.get("guard")
        info = getattr(guard, "permission_mode_info", None)
        if callable(info):
            try:
                out = info()
                if isinstance(out, dict):
                    return out
            except Exception:
                pass
        read = getattr(guard, "permission_mode", None)
        if not callable(read):
            return None
        try:
            value = read()
        except Exception:
            return None
        modes = list(getattr(guard, "PERMISSION_MODES", ("auto", "ask")))
        return {"value": value, "set": "/mode {value}",
                "options": [{"id": m, **PERMISSION_LABELS.get(m, {"label": m.capitalize(), "description": ""})}
                            for m in modes]}

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
        self.desired["controls"] = await asyncio.to_thread(self.build_controls)
        await self.sync_sprite()
        # state last: it names the other slots' ids.
        for name in ("stats", "devices", "controls"):
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
                    await activity(*activity_redacted(self.subchats(), state["agent"], question))
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

    def on_sent(self, chat_id, metadata, message_id, content, *, final: bool, ok: bool, edited: bool = False,
                silent: bool = False) -> None:
        if not ok or not message_id or not content:
            return
        thread = (metadata or {}).get("thread_id") if isinstance(metadata, dict) else None
        topic = self.topic_of(chat_id, thread)
        if topic is None or self.is_app_topic(chat_id, thread):
            return
        key = (topic, int(message_id))
        with self.lock:
            entry = self.pending_notify.get(key)
            if entry is None:
                # Telegram notified once, at the first send: a later edit is not a new notification.
                if silent or int(message_id) in self.saved.get("notified", []):
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
            if not speech.plain(speech.without_speaker(text)).strip():
                continue
            await self.notify(entry["chat"], entry["message_id"], "message", speech.body(text), speech.spoken(text))

    async def notify(self, chat: int, message_id: int | None, kind: str, body: str, spoken: str,
                     interruption: str | None = None) -> None:
        title, private = notify_title(self.subchats(), chat)
        if private:
            body, spoken = private_notification(kind)
        obj = protocol.message("notify", chat=chat, message_id=message_id, kind=kind,
                               interruption=interruption or ("time-sensitive" if kind in ("question", "approval")
                                                             else "active"),
                               title=title, private=private, body=body, spoken=spoken)
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
            self.questions.resolve_callback(data)

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
            if platform == "telegram":
                self.maybe_pending(event)
            if (getattr(event, "text", None) or "").startswith("/"):
                # A command may change what `controls` shows (/mode, /model, /sub…): look again once handled.
                timer = threading.Timer(3.0, self.dirty.set)
                timer.daemon = True
                timer.start()
            return None
        if str(getattr(source, "user_id", "")) != str(owner_id()):
            return {"action": "skip", "reason": "app-topic: not the owner"}
        text = getattr(event, "text", None) or ""
        message_id = getattr(event, "message_id", None) or getattr(source, "message_id", None)
        self.submit(self.handle(text, int(message_id) if message_id else None))
        return {"action": "skip", "reason": "app-topic"}

    def maybe_pending(self, event) -> None:
        """The owner writing while a turn runs in that chat: the message waits for
        the turn's next step (steer) or its own turn. Hermes' ack bubble is off
        (agent/telegram.nix); the app shows it pending, Telegram a reaction."""
        source = getattr(event, "source", None)
        if str(getattr(source, "user_id", "")) != str(owner_id()):
            return
        chat = self.topic_of(getattr(source, "chat_id", None), getattr(source, "thread_id", None))
        text = getattr(event, "text", None) or ""
        message_id = getattr(event, "message_id", None) or getattr(source, "message_id", None)
        if chat is None or not message_id or text.startswith("/") or not self.status.busy(chat):
            return
        self.pending.add(chat, int(message_id), text)
        self.submit(self.react(getattr(source, "chat_id", None), int(message_id), PENDING_REACTION))

    async def react(self, chat_id, message_id: int, emoji: str) -> None:
        bot = self.bot()
        if bot is None:
            return
        try:
            await bot.set_message_reaction(chat_id=chat_id, message_id=message_id, reaction=emoji)
        except Exception as error:
            logger.debug("app_topic: no reaction on %s: %s", message_id, error)

    def taken(self, session_id: str = "", conversation_history=None, user_message=None, **_) -> None:
        """pre_api_request / pre_llm_call: the messages this request carries are no longer pending."""
        texts = []
        for m in (conversation_history or [])[-12:]:
            if isinstance(m, dict) and m.get("role") == "user":
                content = m.get("content")
                texts.append(content if isinstance(content, str) else " ".join(
                    str(p.get("text", "")) for p in content or [] if isinstance(p, dict)))
        if isinstance(user_message, str):
            texts.append(user_message)
        if texts:
            self.pending.taken(self.status.chat_for(session_id), texts, turn_start=user_message is not None)

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
            # The slot messages are old and only edited: buried under the topic's later messages,
            # a client may never page back to them. It reads them by these ids instead.
            slots = {name: slot.get("id") for name, slot in self.saved["slots"].items() if slot.get("id")}
            return {"server_version": self.config.get("server_version", "1"), "protocol": protocol.VERSION,
                    "slots": slots}
        if kind == "stats.refresh":
            # At most one refresh per STATS_REFRESH_GAP: a later one waits for its turn.
            due = max(time.time(), getattr(self, "last_refresh", 0.0) + STATS_REFRESH_GAP)
            self.last_refresh = due
            self.last_stats = min(self.last_stats, due - STATS_EVERY)
            self.dirty.set()
            return {}
        if kind == "pet.generate":
            prompt = str(request.get("prompt") or "").strip()
            if not prompt:
                raise RequestError("bad_request", "prompt is required")
            started = self.start_pet_generation(prompt, request.get("name"))
            return {"started": started}
        if kind == "call.state":
            # A call left on (the app killed mid-call) ends by itself after CALL_MAX.
            self.call_until = time.time() + CALL_MAX if request.get("active") else 0.0
            return {"active": self.call_active()}
        if kind == "app.reinstall":
            return await asyncio.to_thread(self.reinstall, request.get("devices") or [])
        if kind in ("memory.volumes", "memory.lines"):
            return await asyncio.to_thread(self.memory, kind, request)
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
        if kind in ("push.register", "push.unregister"):
            raise RequestError("unavailable", f"{kind} is off on this server")
        raise RequestError("unknown_type", f"unknown request type {kind!r}")

    def memory(self, kind: str, request: dict) -> dict:
        try:
            if kind == "memory.volumes":
                return memory.volumes(owner_id(), self.saved.get("thread"))
            return memory.lines(owner_id(), self.saved.get("thread"), request)
        except memory.Refused as error:
            raise RequestError(error.code, str(error)) from None

    def call_active(self) -> bool:
        return time.time() < self.call_until

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
        chat = self.status.chat_for(kwargs.get("session_id", ""))
        with self.lock:
            self.last_models[str(chat)] = {"provider": provider, "model": model, "at": protocol.now_iso()}

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
                from hermes_cli.config import load_config_readonly

                slug = ((load_config_readonly() or {}).get("display", {}) or {}).get("pet", {}).get("slug", "") or ""
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

    def adopt_pet(self, slug: str, directory: Path, redrawn: bool = False) -> dict:
        changed = slug != self.pet.data["slug"] or redrawn
        version = self.pet.adopt(slug, redrawn)
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

    def pet_max_cost(self) -> float | None:
        value = (self.config.get("pets") or {}).get("max_cost")
        return float(value) if isinstance(value, (int, float)) else None

    def start_pet_generation(self, prompt: str, name=None, on_done=None) -> bool:
        with self.lock:
            if self.pet_busy:
                raise RequestError("busy", "a pet is already being generated")
            self.pet_busy = True

        def run():
            try:
                result = generate_pet(prompt, name, self.pet_max_cost())
                manifest = self.adopt_pet(result["slug"], Path(result["directory"]))
                cost = spent(result.get("report"))
                message = f"Your new pet {manifest['displayName']} has hatched" + (f" ({cost})." if cost else ".")
                outcome = {"ok": True, "pet": manifest, "report": result.get("report")}
            except Exception as error:
                logger.warning("app_topic: pet generation failed: %s", error)
                cost = spent(getattr(error, "report", None))
                message = f"The new pet could not be generated: {error}" + (f" Spent: {cost}." if cost else "")
                outcome = {"ok": False, "error": str(error), "report": getattr(error, "report", None)}
            finally:
                with self.lock:
                    self.pet_busy = False
            self.submit(self.notify(0, None, "message", message, speech.spoken(message)))
            if on_done is not None:
                on_done(outcome)

        threading.Thread(target=run, daemon=True, name="app_topic-pet").start()
        return True


# The commands the app offers natively (docs/app-protocol.md §2.4), chosen
# among Hermes' ~70 and the plugins' for a single never-ending chat on a
# server: no /new, /resume, /sessions (one chat), no /compress (unii), no
# /yolo or /approvals (the permission mode replaces them), no /update or
# /restart (Nix and server-rebuild own those).
# insert: put the text in the composer for the owner to finish; send: send as is.
# Labels and icons are the app's (the protocol's table), to keep the slot small.
COMMANDS = [
    {"id": "stop", "send": "/stop", "where": "any"},
    {"id": "retry", "send": "/retry", "where": "any"},
    {"id": "undo", "send": "/undo", "where": "any"},
    {"id": "btw", "insert": "/btw ", "where": "any"},
    {"id": "bg", "insert": "/bg ", "where": "any"},
    {"id": "goal", "insert": "/goal ", "where": "any"},
    {"id": "agents", "send": "/agents", "where": "any"},
    {"id": "status", "send": "/status", "where": "any"},
    {"id": "usage", "send": "/usage", "where": "any"},
    {"id": "reasoning", "control": "picker", "send": "/reasoning {value}",
     "options": ["low", "medium", "high"], "where": "any"},
    {"id": "model", "control": "model", "where": "any"},
    {"id": "permissions", "control": "permission_mode", "where": "any",
     "icon": "lock.shield"},
    {"id": "sub.new", "control": "subchat_form", "send": "/sub new {preset} {name}",
     "where": "main"},
    {"id": "sub.show", "send": "/sub", "where": "subchat"},
    {"id": "sub.set", "insert": "/sub set ", "where": "subchat"},
    {"id": "sub.lock", "send": "/sub lock", "where": "encrypted"},
    {"id": "sub.end", "send": "/sub end", "where": "subchat",
     "confirm": "The sub-chat and its memory are deleted."},
    {"id": "pause", "send": "/pause", "where": "main",
     "confirm": "Hermes stops starting new work until /pause off."},
    {"id": "resume", "send": "/pause off", "where": "main"},
]


PERMISSION_LABELS = {
    "auto": {"label": "Auto", "description": "Safe actions run; a reviewer judges the rest and blocks risky ones. "
                                             "You are asked after repeated blocks."},
    "ask": {"label": "Ask", "description": "Every action but reading asks you first."},
}


class RequestError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


_NO_REPLY = object()


def _unii_chat(runtime, key: str):
    policy_module = sys.modules.get(type(runtime.policies).__module__)
    return policy_module.Chat.from_key(key)


def generate_pet(prompt: str, name=None, max_cost: float | None = None, work: Path | None = None) -> dict:
    """One image for the whole sheet, rows redrawn alone when they fail
    (hatch.py), packed into the Codex atlas and saved to
    ~/.hermes/pets/<slug>/, then made the active pet. Stops at the provider's
    first account-level refusal (ProviderRefused) and never spends more than
    *max_cost* (USD); the result's ``report`` says what was spent and done."""
    import tempfile

    from agent.pet import store
    from agent.pet.generate import imagegen

    from . import hatch

    sprite = imagegen.resolve_provider(require_references=True)
    hatch.openrouter_knobs(sprite.provider)
    limit = hatch.DEFAULT_MAX_COST if max_cost is None else float(max_cost)
    with tempfile.TemporaryDirectory(prefix="pet-hatch-") as scratch:
        atlas_image, report = hatch.hatch(prompt, sprite=sprite, work=work or Path(scratch), max_cost=limit)
        display = (str(name).strip() if name else "") or _name_from(prompt)
        pet = store.register_local_pet(atlas_image, slug=store.unique_slug(display), display_name=display,
                                       description=prompt)
    try:
        from hermes_cli.config import load_config, save_config

        config = load_config() or {}
        selected = config.setdefault("display", {}).setdefault("pet", {})
        selected.update(slug=pet.slug, enabled=True)
        save_config(config)
    except Exception:
        # Managed mode refuses config edits: the plugin follows the newest generated pet instead.
        logger.debug("app_topic: could not select the pet in config.yaml", exc_info=True)
    return {"slug": pet.slug, "directory": str(pet.directory), "report": report}


def redraw_pet_rows(slug: str, rows: list[str], max_cost: float | None = None, work: Path | None = None) -> dict:
    """Redraws some rows of an installed pet (hatch.redraw) and saves it in
    place; the rest of its sheet is kept."""
    import tempfile

    from agent.pet import store
    from agent.pet.generate import imagegen

    from . import hatch

    pet = store.load_pet(slug)
    if pet is None or not pet.exists:
        raise hatch.HatchFailed(f"no pet '{slug}'")
    sprite = imagegen.resolve_provider(require_references=True)
    hatch.openrouter_knobs(sprite.provider)
    limit = hatch.DEFAULT_MAX_COST if max_cost is None else float(max_cost)
    concept = pet.description or pet.display_name
    with tempfile.TemporaryDirectory(prefix="pet-redraw-") as scratch:
        atlas_image, report = hatch.redraw(pet.spritesheet, rows, concept, sprite=sprite,
                                           work=work or Path(scratch), max_cost=limit)
        store.register_local_pet(atlas_image, slug=pet.slug, display_name=pet.display_name,
                                 description=pet.description)
    return {"slug": pet.slug, "directory": str(pet.directory), "report": report}


def spent(report: dict | None) -> str:
    """"$0.31 of $0.60" for what a hatch spent, or ""."""
    budget = (report or {}).get("budget") or {}
    if "spent" not in budget:
        return ""
    return f"${budget['spent']:.2f} of the ${budget['limit']:.2f} budget"


def _name_from(prompt: str) -> str:
    words = [w for w in prompt.replace(",", " ").split() if w.isalpha()][:2]
    return " ".join(w.capitalize() for w in words) or "Pet"
