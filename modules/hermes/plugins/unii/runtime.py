"""The plugin's process-wide state: the open volumes and their compactors, the
keys of unlocked volumes (in memory only), the sub-chat policies, and the
gateway handles that the hooks capture."""

from __future__ import annotations

import logging
import os
import shutil
import threading
import time
from typing import Callable

from .compactor import Compactor
from .policy import MAIN, Chat, Policies, Policy, own_volume, readable_volumes, write_volume
from .volume import Volume, VolumeLocked, unlock_key

logger = logging.getLogger(__name__)


class Runtime:
    def __init__(self, home: str, config: dict, complete: Callable[[list[dict]], str]):
        self.config = config
        self.root = os.path.join(home, "unii")
        self.volumes_dir = os.path.join(self.root, "volumes")
        os.makedirs(self.volumes_dir, mode=0o700, exist_ok=True)
        self.policies = Policies(config, self.root)
        self.complete = complete
        self.view_bytes = int(config.get("view_bytes", 64_000))
        self.line_bytes = int(config.get("line_bytes", 512))
        self.uzu_model = config.get("uzu_model", "")
        # A turn waits this long for the last messages' summaries, then goes on
        # with "(not summarized yet: zoom it)" lines.
        self.summary_wait = float(config.get("summary_wait_seconds", 20))
        self.workers = int(config.get("compaction_workers", 4))
        self.keys: dict[str, bytes] = {}
        self.sessions: dict[str, Chat] = {}
        self.gateway = None
        self.session_store = None
        self._volumes: dict[str, Volume] = {}
        self._compactors: dict[str, Compactor] = {}
        self._lock = threading.RLock()

    # ── volumes ──────────────────────────────────────────────────────────

    def encrypted(self, name: str, policy: Policy | None = None) -> bool:
        if name == MAIN:
            return False
        if self.config.get("volumes", {}).get(name, {}).get("encrypted"):
            return True
        if os.path.exists(os.path.join(self.volumes_dir, name, "meta.json")):
            return True
        return bool(policy and policy.encrypted)

    def volume(self, name: str, policy: Policy | None = None) -> Volume:
        """The open volume; raises VolumeLocked for an encrypted one without its key."""
        with self._lock:
            if name in self._volumes:
                return self._volumes[name]
            encrypted = self.encrypted(name, policy)
            volume = Volume(self.volumes_dir, name, encrypted=encrypted, key=self.keys.get(name))
            self._volumes[name] = volume
            self._compactors[name] = Compactor(volume, self.complete, self.line_bytes, self.workers)
            return volume

    def is_locked(self, name: str, policy: Policy | None = None) -> bool:
        return self.encrypted(name, policy) and name not in self.keys

    def unlock(self, name: str, passphrase: str) -> None:
        key = unlock_key(os.path.join(self.volumes_dir, name), name, passphrase)
        with self._lock:
            self.keys[name] = key
            self._close(name)

    def lock(self, name: str) -> None:
        with self._lock:
            self.keys.pop(name, None)
            self._close(name)

    def _close(self, name: str) -> None:
        self._volumes.pop(name, None)
        compactor = self._compactors.pop(name, None)
        if compactor:
            compactor.stop()

    def append(self, name: str, kind: str, text: str, policy: Policy | None = None) -> None:
        volume = self.volume(name, policy)
        ids = volume.append(kind, text)
        self._compactors[name].appended(ids)

    def maintain(self, name: str) -> None:
        """After a turn: retry failed compactions, shrink the view if it is due."""
        compactor = self._compactors.get(name)
        if compactor:
            compactor.retry_failed()
        volume = self._volumes.get(name)
        if volume:
            volume.merge(self.view_bytes)

    # ── chats ────────────────────────────────────────────────────────────

    def chat_volumes(self, chat: Chat) -> tuple[Policy, str, list[str]]:
        policy = self.policies.policy(chat)
        return policy, write_volume(chat, policy), readable_volumes(chat, policy)

    def model_override(self, policy: Policy) -> dict | None:
        if not policy.model:
            return None
        provider, _, model = policy.model.partition(":")
        if provider == "uzu" and model in ("", "local"):
            model = self.uzu_model
        return {"provider": provider, "model": model}

    def apply_model(self, chat: Chat, policy: Policy) -> None:
        """Pin the sub-chat's model on its gateway sessions, the way `/model` does.

        The gateway reads the persisted override back only when it holds none in
        memory (gateway/run_agent_cache.py, _rehydrate_session_model_override),
        so the in-memory one is dropped whenever the persisted one changes."""
        store = self.session_store
        if store is None or chat.is_main:
            return
        override = self.model_override(policy)
        try:
            for entry in store.list_sessions():
                key = entry.session_key
                if f":{chat.key}" not in key or store.get_model_override(key) == override:
                    continue
                store.set_model_override(key, override)
                peek = getattr(self.gateway, "_peek_session_state", None)
                state = peek(key) if peek else None
                if state is not None:
                    state.conversation.model_override = None
        except Exception:
            logger.warning("unii: could not set the model of %s", chat.key, exc_info=True)

    def wipe_chat(self, chat: Chat, *, reset_routes: bool = True, keep: tuple[str, ...] = ()) -> None:
        """Delete everything a temporary sub-chat left: its private volume, its Hermes
        sessions (but `keep`), its key. A shared named volume is kept. `reset_routes`
        moves the chat to a fresh session; a /new already did."""
        _, own, _ = self.chat_volumes(chat)
        if own == own_volume(chat):
            with self._lock:
                self._close(own)
                self.keys.pop(own, None)
            shutil.rmtree(os.path.join(self.volumes_dir, own), ignore_errors=True)
        store = self.session_store
        if store is not None and reset_routes:
            try:
                for entry in store.list_sessions():
                    if f":{chat.key}" in entry.session_key:
                        store.reset_session(entry.session_key)
            except Exception:
                logger.warning("unii: could not reset the sessions of %s", chat.key, exc_info=True)
        delete_sessions([sid for sid in self.policies.forget_sessions(chat) if sid not in keep])
        for sid, value in list(self.sessions.items()):
            if value == chat:
                self.sessions.pop(sid, None)

    def sweep(self, now: float | None = None) -> list[Chat]:
        expired = self.policies.expired(now or time.time())
        for chat in expired:
            logger.info("unii: %s expired, wiping it", chat.key)
            self.wipe_chat(chat)
        return expired


def _session_db():
    from hermes_state import SessionDB

    return SessionDB()


def delete_sessions(session_ids: list[str]) -> None:
    if not session_ids:
        return
    try:
        db = _session_db()
    except Exception:
        logger.warning("unii: no session database to delete from", exc_info=True)
        return
    try:
        for sid in session_ids:
            try:
                db.delete_session(sid)
            except Exception:
                logger.warning("unii: could not delete session %s", sid, exc_info=True)
    finally:
        db.close()


def scrub_session(session_id: str) -> None:
    """Drop an encrypted chat's plaintext transcript; its encrypted log is the record."""
    try:
        db = _session_db()
    except Exception:
        logger.warning("unii: no session database to scrub", exc_info=True)
        return
    try:
        db.clear_messages(session_id)
    except Exception:
        logger.warning("unii: could not scrub session %s", session_id, exc_info=True)
    finally:
        db.close()


__all__ = ["Runtime", "VolumeLocked", "delete_sessions", "scrub_session"]
