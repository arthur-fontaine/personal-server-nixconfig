"""Call mode: a WebSocket where the owner talks to Hermes (docs/app-protocol.md §6).

Hermes answers, not a separate voice model: each utterance is transcribed
with Hermes' configured STT, becomes a main-chat turn (prefixed 🎙, so the
prompt makes the answer short and speakable), and the reply is spoken with
Hermes' configured TTS sentence by sentence as it streams (drafts, then the
final message). The turn and its answer stay in the chat as text.

Its own thread and event loop: audio must not wait on the gateway's.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import secrets
import subprocess
import tempfile
import threading
import time
import wave
from pathlib import Path

from . import speech
from .protocol import now_iso

logger = logging.getLogger("app_topic.call")

RATE = 24000
FRAME_BYTES = 1920  # 40 ms of PCM16 mono at 24 kHz
TOKEN_TTL = 300
SILENCE_END = 0.7
IDLE_END = 600
MARK = "🎙"
_SENTENCE_END = re.compile(r"[.!?…:](?=\s|$)|\n")


def rms(pcm: bytes) -> float:
    import numpy as np

    samples = np.frombuffer(pcm[: len(pcm) - len(pcm) % 2], dtype="<i2").astype("float32")
    return float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0


def split_ready(text: str, offset: int, final: bool) -> tuple[list[str], int]:
    """Sentences of `text` past `offset` that are complete (all of it when final)."""
    rest = text[offset:]
    if final:
        return ([rest.strip()] if rest.strip() else []), len(text)
    out, consumed = [], 0
    for match in _SENTENCE_END.finditer(rest):
        chunk = rest[consumed: match.end()].strip()
        # Wait for a few words: a lone "1." of a list is not worth a TTS call.
        if len(chunk) >= 12 or match.group(0) == "\n":
            if chunk:
                out.append(chunk)
            consumed = match.end()
    return out, offset + consumed


class Tokens:
    def __init__(self):
        self.lock = threading.Lock()
        self.items: dict[str, float] = {}

    def issue(self) -> tuple[str, float]:
        token, expires = secrets.token_urlsafe(32), time.time() + TOKEN_TTL
        with self.lock:
            self.items = {t: e for t, e in self.items.items() if e > time.time()}
            self.items[token] = expires
        return token, expires

    def take(self, token: str) -> bool:
        with self.lock:
            expires = self.items.pop(token or "", None)
        return bool(expires and expires > time.time())


def synthesize(text: str, ffmpeg: str) -> bytes:
    """PCM16LE 24 kHz mono for `text`, through Hermes' TTS provider."""
    from tools.tts_tool import text_to_speech_tool

    with tempfile.TemporaryDirectory(prefix="hermes-call-") as tmp:
        result = json.loads(text_to_speech_tool(text, output_path=os.path.join(tmp, "say.mp3")))
        if not result.get("success"):
            raise RuntimeError(result.get("error") or "TTS failed")
        paths = result.get("file_paths") or [result["file_path"]]
        out = b""
        for path in paths:
            out += subprocess.run(
                [ffmpeg, "-nostdin", "-loglevel", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                capture_output=True, check=True, timeout=60).stdout
            try:
                os.unlink(path)
            except OSError:
                pass
        return out


def transcribe(pcm: bytes) -> str:
    from tools.transcription_tools import transcribe_audio

    with tempfile.TemporaryDirectory(prefix="hermes-call-") as tmp:
        path = os.path.join(tmp, "utterance.wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm)
        result = transcribe_audio(path, source="voice_mode")
    if not result.get("success", True) and not result.get("transcript"):
        raise RuntimeError(result.get("error") or "transcription failed")
    return (result.get("transcript") or result.get("text") or "").strip()


class Call:
    """One connected call."""

    def __init__(self, server: "CallServer", ws):
        self.server, self.ws = server, ws
        self.loop = asyncio.get_running_loop()
        self.audio = bytearray()
        self.speaking_input = False
        self.silence_since: float | None = None
        self.last_activity = time.time()
        self.say_queue: asyncio.Queue = asyncio.Queue()
        self.generation = 0
        self.awaiting = False
        # The reply being spoken: drafts and then the final message carry the
        # same growing text under different ids, so it is followed by content.
        self.reply_text = ""
        self.reply_offset = 0
        self.closed = False
        self.threshold = server.threshold

    async def send_json(self, obj: dict) -> None:
        if not self.closed:
            try:
                await self.ws.send_str(json.dumps(obj, ensure_ascii=False))
            except Exception:
                self.closed = True

    async def state(self, state: str) -> None:
        await self.send_json({"type": "state", "state": state})

    # ── input ────────────────────────────────────────────────────────────

    async def on_audio(self, pcm: bytes) -> None:
        self.last_activity = time.time()
        level = rms(pcm)
        now = time.monotonic()
        if level >= self.threshold:
            if not self.speaking_input and self.say_queue.qsize() + int(self.server.busy_speaking(self)) > 0:
                await self.interrupt()  # barge-in
            self.speaking_input = True
            self.silence_since = None
        elif self.speaking_input and self.silence_since is None:
            self.silence_since = now
        if self.speaking_input:
            self.audio.extend(pcm)
        if self.speaking_input and self.silence_since is not None and now - self.silence_since >= SILENCE_END:
            await self.end_input()

    async def end_input(self) -> None:
        pcm, self.audio = bytes(self.audio), bytearray()
        self.speaking_input, self.silence_since = False, None
        if len(pcm) < RATE * 2 * 0.3:  # under 300 ms: a cough, not a sentence
            return
        await self.state("thinking")
        try:
            text = await asyncio.to_thread(transcribe, pcm)
        except Exception as error:
            await self.send_json({"type": "error", "message": f"transcription failed: {error}"})
            await self.state("listening")
            return
        if not text:
            await self.state("listening")
            return
        await self.send_json({"type": "transcript", "role": "user", "text": text, "final": True})
        self.awaiting = True
        if not await asyncio.to_thread(self.server.inject, f"{MARK} {text}"):
            await self.send_json({"type": "error", "message": "Hermes could not take the message"})
            self.awaiting = False
            await self.state("listening")

    async def interrupt(self) -> None:
        self.generation += 1
        while not self.say_queue.empty():
            self.say_queue.get_nowait()
        await self.send_json({"type": "clear"})
        await self.state("listening")

    # ── output ───────────────────────────────────────────────────────────

    def on_reply(self, message_id: int, text: str, final: bool) -> None:
        """From the gateway's loop: Hermes' text in the main chat, cumulative."""
        if not self.awaiting:
            return
        body = speech.split_override(text)[0].rstrip("▉▌█ ")
        done = self.reply_text[: self.reply_offset]
        if not body.startswith(done):
            self.reply_offset = 0  # another message: start over
        chunks, self.reply_offset = split_ready(body, self.reply_offset, final)
        self.reply_text = body
        if final:
            self.reply_text, self.reply_offset = "", 0
        generation = self.generation
        for chunk in chunks:
            spoken = speech.spoken_full(chunk)
            if spoken:
                self.loop.call_soon_threadsafe(self.say_queue.put_nowait, (generation, chunk, spoken))

    async def speaker(self) -> None:
        while not self.closed:
            generation, text, spoken = await self.say_queue.get()
            if generation != self.generation:
                continue
            try:
                pcm = await asyncio.to_thread(synthesize, spoken, self.server.ffmpeg)
            except Exception as error:
                await self.send_json({"type": "error", "message": f"speech failed: {error}"})
                continue
            if generation != self.generation:
                continue
            await self.state("speaking")
            await self.send_json({"type": "transcript", "role": "assistant", "text": text, "final": True})
            for start in range(0, len(pcm), FRAME_BYTES * 25):
                if generation != self.generation or self.closed:
                    break
                try:
                    await self.ws.send_bytes(pcm[start: start + FRAME_BYTES * 25])
                except Exception:
                    self.closed = True
                    break
            if self.say_queue.empty() and generation == self.generation:
                await self.state("listening")


class CallServer:
    def __init__(self, config: dict, app):
        self.config = config
        self.app = app
        self.tokens = Tokens()
        self.port = int(config.get("port", 8787))
        self.bind = config.get("bind", "0.0.0.0")
        self.public_url = config.get("public_url") or None
        self.lan_host = config.get("lan_host") or "localhost"
        self.ffmpeg = config.get("ffmpeg") or "ffmpeg"
        self.threshold = float(config.get("vad_threshold", 700))
        self.current: Call | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.runner = None
        self.inject_fn = None  # set by the plugin: ctx.inject_message into the main chat
        app.notify_listeners.append(self.on_main_chat)

    # ── App topic ────────────────────────────────────────────────────────

    async def start_request(self, request: dict, message_id) -> dict:
        token, expires = self.tokens.issue()
        return {"url": self.public_url, "lan_url": f"ws://{self.lan_host}:{self.port}/call",
                "token": token, "expires": now_iso(expires)}

    def on_main_chat(self, chat: int, message_id: int, text: str, final: bool) -> None:
        call = self.current
        if call is not None and chat == 0:
            call.on_reply(message_id, text, final)

    def busy_speaking(self, call: Call) -> bool:
        return False

    def inject(self, text: str) -> bool:
        return bool(self.inject_fn and self.inject_fn(text))

    # ── server ───────────────────────────────────────────────────────────

    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True, name="app_topic-call").start()

    def _run(self) -> None:
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self._serve())
        self.loop.run_forever()

    async def _serve(self) -> None:
        from aiohttp import web

        app = web.Application()
        app.router.add_get("/call", self.handle)
        app.router.add_get("/health", lambda request: web.json_response({"ok": True}))
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, self.bind, self.port)
        try:
            await site.start()
            logger.info("app_topic: call endpoint on %s:%s", self.bind, self.port)
        except OSError as error:
            logger.warning("app_topic: call endpoint not started: %s", error)

    async def handle(self, request):
        from aiohttp import WSMsgType, web

        auth = request.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else request.query.get("token", "")
        if not self.tokens.take(token):
            return web.Response(status=401, text="bad or expired token")
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=1 << 20)
        await ws.prepare(request)
        if self.current is not None and not self.current.closed:
            await ws.send_str(json.dumps({"type": "end", "reason": "busy"}))
            await ws.close()
            return ws
        call = Call(self, ws)
        self.current = call
        speaker = asyncio.create_task(call.speaker())
        reason = "hangup"
        await call.state("listening")
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(ws.receive(), timeout=30)
                except asyncio.TimeoutError:
                    if time.time() - call.last_activity > IDLE_END:
                        reason = "timeout"
                        break
                    continue
                if msg.type == WSMsgType.BINARY:
                    await call.on_audio(msg.data)
                elif msg.type == WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                    except ValueError:
                        continue
                    kind = data.get("type")
                    if kind == "input.end":
                        await call.end_input()
                    elif kind == "interrupt":
                        await call.interrupt()
                    elif kind == "hangup":
                        break
                elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED, WSMsgType.ERROR):
                    break
        except Exception:
            logger.warning("app_topic: call failed", exc_info=True)
            reason = "error"
        finally:
            await call.send_json({"type": "end", "reason": reason})
            call.closed = True
            speaker.cancel()
            if self.current is call:
                self.current = None
            await ws.close()
        return ws
