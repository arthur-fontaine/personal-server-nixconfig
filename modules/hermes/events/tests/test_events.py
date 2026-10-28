"""Tests for hermes_events. Run with Hermes' own interpreter (the flake check
`events`), from modules/hermes/events:

    python3 -I tests/test_events.py
"""

import asyncio
import hashlib
import hmac
import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402

from hermes_events.core import Chat, Message, Pipeline, Seen  # noqa: E402
from hermes_events.hermes import HermesSink  # noqa: E402
from hermes_events.sources import imessage_message, whatsapp_app, whatsapp_message  # noqa: E402
from hermes_events.triage import UzuTriage  # noqa: E402
from hermes_events.instagram import instagram_message  # noqa: E402

SECRET = "s3cret"
NOW = time.time()
ISO_NOW = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW))


def wa(text="on prend un verre ce soir ?", id="A1", chat="33611111111@s.whatsapp.net", from_me=False, **extra):
    return {"Chat": chat, "ID": id, "SenderJID": chat, "Timestamp": ISO_NOW, "FromMe": from_me,
            "Text": text, "ChatName": "Martin", **extra}


class FakeTriage:
    def __init__(self, verdict={"urgency": "today"}):
        self.verdict, self.events = verdict, []

    async def decide(self, event, *, fail_open):
        self.events.append((event, fail_open))
        return self.verdict


class FakeSink:
    def __init__(self):
        self.events = []

    async def post(self, event, route="events"):
        self.events.append(event if route == "events" else {**event, "route": route})
        return True


def pipeline(tmp, triage=None, sink=None, batch=0.05, max_batch=None):
    return Pipeline(triage=triage or FakeTriage(), sink=sink or FakeSink(), seen=Seen(os.path.join(tmp, "seen.json")),
                    batch_seconds=batch, max_age_seconds=600, max_batch_seconds=max_batch)


class ParseTest(unittest.TestCase):
    def test_whatsapp(self):
        chat, message, from_me = whatsapp_message(wa())
        self.assertEqual((chat.key, chat.name, chat.is_group, from_me), ("whatsapp:33611111111@s.whatsapp.net", "Martin", False, False))
        self.assertAlmostEqual(message.time, NOW, delta=1)
        self.assertIsNone(whatsapp_message({"EventType": "receipt", "Chat": "x", "MessageIDs": ["1"]}))
        group, _, _ = whatsapp_message(wa(chat="1203@g.us", ChatName="Foot"))
        self.assertTrue(group.is_group)
        _, photo, _ = whatsapp_message(wa(text="", Media={"Type": "image", "Caption": "regarde"}))
        self.assertEqual(photo.text, "[image] regarde")

    def test_imessage(self):
        line = {"chat_id": 7, "guid": "G1", "sender": "+33622222222", "sender_name": "Léa", "is_from_me": False,
                "text": "Tu es libre samedi ?", "created_at": ISO_NOW}
        chat, message, from_me = imessage_message(line)
        self.assertEqual((chat.key, chat.name, message.text, from_me), ("imessage:7", "Léa", "Tu es libre samedi ?", False))
        self.assertIsNone(imessage_message({**line, "is_reaction": True}))
        self.assertIsNone(imessage_message({**line, "edited_at": ISO_NOW}))


class InstagramTest(unittest.TestCase):
    def test_notifications(self):
        chat, message = instagram_message({"title": "martin.d", "body": "bubble tea ?", "tag": "t"}, NOW)
        self.assertEqual((chat.key, message.text), ("instagram:martin.d", "bubble tea ?"))
        chat, _ = instagram_message({"title": "Instagram", "body": "martin.d: ce soir", "tag": ""}, NOW)
        self.assertEqual(chat.name, "martin.d")
        self.assertIsNone(instagram_message({"title": "", "body": ""}, NOW))


class PipelineTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp()

    async def test_a_burst_is_one_event_and_replays_are_dropped(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink)
        for parsed in (whatsapp_message(wa(id="A1")), whatsapp_message(wa("à 19h ?", id="A2")),
                       whatsapp_message(wa(id="A1"))):  # a replay
            p.message(parsed[0], parsed[1])
        await asyncio.sleep(0.15)
        self.assertEqual(len(sink.events), 1)
        event = sink.events[0]
        self.assertIn("2 new messages", event["summary"])
        self.assertIn("Martin: à 19h ?", event["messages"])
        self.assertEqual(event["urgency"], "today")
        # Seen survives a restart.
        p2 = pipeline(self.tmp, sink=sink)
        chat, message, _ = whatsapp_message(wa(id="A2"))
        p2.message(chat, message)
        await asyncio.sleep(0.15)
        self.assertEqual(len(sink.events), 1)

    async def test_a_quiet_window_with_a_cap(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink, batch=0.1, max_batch=0.35)
        for i in range(6):  # one message every 0.08 s: never quiet for 0.1 s
            chat, message, _ = whatsapp_message(wa(f"m{i}", id=f"Q{i}"))
            p.message(chat, message)
            await asyncio.sleep(0.08)
        # The cap flushed once mid-stream; the rest follows after the quiet window.
        await asyncio.sleep(0.25)
        self.assertEqual(len(sink.events), 2)
        self.assertEqual(sum(e["messages"].count("Martin:") for e in sink.events), 6)

    async def test_notices_and_system(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink)
        p.notice("homekit", "door", "Front door opened", "[Front Door] contact open", id="d1")
        p.notice("homekit", "door", "Front door opened", "[Front Door] contact open", id="d1")
        p.system("disk", "Disk almost full")
        await asyncio.sleep(0.05)
        self.assertEqual([e["key"] for e in sink.events], ["homekit:door", "system:disk"])
        self.assertEqual(sink.events[1]["route"], "system")

    async def test_old_messages_and_answered_chats(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink)
        chat = Chat("whatsapp", "x@s.whatsapp.net", "X")
        p.message(chat, Message("old", NOW - 3600, "X", "history sync"))
        p.message(chat, Message("new", NOW, "X", "dispo ?"))
        p.own_message(chat)  # the user answered within the window
        await asyncio.sleep(0.15)
        self.assertEqual(sink.events, [])

    async def test_triage_drops(self):
        sink = FakeSink()
        p = pipeline(self.tmp, triage=FakeTriage(None), sink=sink)
        chat, message, _ = whatsapp_message(wa("😂"))
        p.message(chat, message)
        await asyncio.sleep(0.15)
        self.assertEqual(sink.events, [])


class TriageTest(unittest.IsolatedAsyncioTestCase):
    async def serve(self, handler):
        app = web.Application()
        app.router.add_post("/v1/chat/completions", handler)
        server = TestServer(app)
        await server.start_server()
        self.addAsyncCleanup(server.close)
        return str(server.make_url("/v1/chat/completions"))

    async def test_typed_answer(self):
        requests = []

        async def uzu(request):
            requests.append(await request.json())
            content = json.dumps({"may_need_the_user": True, "urgency": "now"})
            return web.json_response({"choices": [{"message": {"content": content}}]})

        triage = UzuTriage(await self.serve(uzu), "qwen")
        event = {"key": "k", "summary": "A new message", "messages": "Martin: verre ?", "is_group": False}
        self.assertEqual(await triage.decide(event, fail_open=False), {"urgency": "now"})
        self.assertEqual(requests[0]["response_format"]["type"], "json_schema")
        self.assertFalse(requests[0]["enable_thinking"])

    async def test_failure_policy(self):
        async def broken(request):
            return web.Response(status=500)

        triage = UzuTriage(await self.serve(broken), "qwen")
        event = {"key": "k", "summary": "s", "messages": "m"}
        self.assertEqual(await triage.decide(event, fail_open=True), {"urgency": "unknown"})
        self.assertIsNone(await triage.decide(event, fail_open=False))


class HermesTest(unittest.IsolatedAsyncioTestCase):
    async def test_signature_is_what_hermes_accepts(self):
        # Hermes' own verifier pieces (gateway/platforms/webhook.py).
        from gateway.platforms.webhook import _hex_hmac, _hmac_str_equal

        received = []

        async def hermes(request):
            body = await request.read()
            ts = request.headers["X-Webhook-Timestamp"]
            ok = _hmac_str_equal(request.headers["X-Webhook-Signature-V2"], _hex_hmac(SECRET, ts.encode() + b"." + body))
            received.append((ok, json.loads(body)))
            return web.json_response({"status": "accepted"}, status=202 if ok else 401)

        app = web.Application()
        app.router.add_post("/webhooks/events", hermes)
        server = TestServer(app)
        await server.start_server()
        self.addAsyncCleanup(server.close)
        sink = HermesSink(str(server.make_url("/webhooks")), SECRET, "839917731")
        self.assertTrue(await sink.post({"key": "k", "summary": "s"}))
        self.assertEqual(received[0][0], True)
        self.assertEqual(received[0][1]["owner"], "839917731")


class WhatsAppEndpointTest(unittest.IsolatedAsyncioTestCase):
    async def test_only_signed_posts(self):
        sink = FakeSink()
        p = pipeline(tempfile.mkdtemp(), sink=sink)
        client = TestClient(TestServer(whatsapp_app(p, SECRET)))
        await client.start_server()
        self.addAsyncCleanup(client.close)
        body = json.dumps(wa()).encode()
        bad = await client.post("/whatsapp", data=body, headers={"X-Wacli-Signature": "sha256=00"})
        self.assertEqual(bad.status, 401)
        signature = "sha256=" + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
        good = await client.post("/whatsapp", data=body, headers={"X-Wacli-Signature": signature})
        self.assertEqual(good.status, 204)
        await asyncio.sleep(0.15)
        self.assertEqual(len(sink.events), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
