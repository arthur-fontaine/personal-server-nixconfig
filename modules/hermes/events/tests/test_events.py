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

from hermes_events.core import Chat, Journal, Message, Pipeline, Seen  # noqa: E402
from hermes_events.hermes import HermesSink  # noqa: E402
from hermes_events.sources import imessage_message, whatsapp_app, whatsapp_message  # noqa: E402
from hermes_events.triage import UzuTriage  # noqa: E402
from hermes_events.browser import (  # noqa: E402
    Instagram, keep_discord, Thread, instagram_message, notification_message, resolve_instagram, thread_id_of)
from hermes_events.history import Context, History, imessage_earlier, whatsapp_earlier  # noqa: E402
from hermes_events import pollers  # noqa: E402
import sqlite3  # noqa: E402

SECRET = "s3cret"
NOW = time.time()
ISO_NOW = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW))


def wa(text="on prend un verre ce soir ?", id="A1", chat="33611111111@s.whatsapp.net", from_me=False, **extra):
    return {"Chat": chat, "ID": id, "SenderJID": chat, "Timestamp": ISO_NOW, "FromMe": from_me,
            "Text": text, "ChatName": "Zoé", **extra}


async def eventually(check, timeout=3.0):
    """Wait until `check()` holds: fixed sleeps fail on a loaded machine."""
    deadline = time.time() + timeout
    while not check() and time.time() < deadline:
        await asyncio.sleep(0.02)


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
        self.assertEqual((chat.key, chat.name, chat.is_group, from_me), ("whatsapp:33611111111@s.whatsapp.net", "Zoé", False, False))
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
        chat, message = instagram_message({"title": "zoe.martin", "body": "on se voit ?", "tag": "t", "host": "www.instagram.com"}, NOW)
        self.assertEqual((chat.key, message.text), ("instagram:zoe.martin", "on se voit ?"))
        chat, _ = instagram_message({"title": "Instagram", "body": "zoe.martin: ce soir", "tag": "", "host": "www.instagram.com"}, NOW)
        self.assertEqual(chat.name, "zoe.martin")
        self.assertIsNone(instagram_message({"title": "", "body": ""}, NOW))
        # The message alone: the sender is unknown, not its first words.
        chat, message = instagram_message({"title": "Instagram", "body": "on peut regarder ?", "host": "www.instagram.com"}, NOW)
        self.assertEqual((chat.name, message.text), ("Instagram", "on peut regarder ?"))
        self.assertIn("does not name", message.sender)
        chat, _ = instagram_message({"title": "Instagram", "body": "x", "data": '{"sender":"t","thread":"1"}', "host": "www.instagram.com"}, NOW)
        self.assertEqual(chat.name, "Instagram")
        chat, message = notification_message({"title": "Zoé (#général, Les copains)", "body": "on se voit ?", "host": "discord.com"}, NOW)
        self.assertEqual((chat.source, chat.name, message.text), ("discord", "Zoé (#général, Les copains)", "on se voit ?"))


class PipelineTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp()

    async def test_a_burst_is_one_event_and_replays_are_dropped(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink)
        for parsed in (whatsapp_message(wa(id="A1")), whatsapp_message(wa("à 19h ?", id="A2")),
                       whatsapp_message(wa(id="A1"))):  # a replay
            p.message(parsed[0], parsed[1])
        await eventually(lambda: sink.events)
        self.assertEqual(len(sink.events), 1)
        event = sink.events[0]
        self.assertIn("2 new messages", event["summary"])
        self.assertIn("Zoé: à 19h ?", event["messages"])
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
        self.assertEqual(sum(e["messages"].count("Zoé:") for e in sink.events), 6)

    async def test_notices_and_system(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink)
        p.notice("homekit", "door", "Front door opened", "[Front Door] contact open", id="d1")
        p.notice("homekit", "door", "Front door opened", "[Front Door] contact open", id="d1")
        p.system("disk", "Disk almost full")
        await eventually(lambda: len(sink.events) >= 2)
        self.assertEqual([e["key"] for e in sink.events], ["homekit:door", "system:disk"])
        self.assertEqual(sink.events[1]["route"], "system")

    async def test_old_messages_and_answered_chats(self):
        sink = FakeSink()
        p = pipeline(self.tmp, sink=sink)
        chat = Chat("whatsapp", "x@s.whatsapp.net", "X")
        p.message(chat, Message("old", NOW - 3600, "X", "history sync"))
        p.message(chat, Message("new", NOW, "X", "tu es là ?"))
        p.own_message(chat)  # the user answered within the window
        await asyncio.sleep(0.15)
        self.assertEqual(sink.events, [])

    async def test_triage_drops(self):
        sink = FakeSink()
        p = pipeline(self.tmp, triage=FakeTriage(None), sink=sink)
        p.journal = Journal(os.path.join(self.tmp, "recent.jsonl"))
        chat, message, _ = whatsapp_message(wa("😂"))
        p.message(chat, message)
        await asyncio.sleep(0.15)
        self.assertEqual(sink.events, [])
        # Dropped, but kept where Hermes can look.
        with open(os.path.join(self.tmp, "recent.jsonl")) as f:
            records = [json.loads(line) for line in f]
        self.assertEqual(len(records), 1)
        self.assertIn("😂", records[0]["messages"])
        self.assertTrue(records[0]["outcome"].startswith("not proposed"))


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
        event = {"key": "k", "summary": "A new message", "messages": "Zoé: verre ?", "is_group": False}
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
        await eventually(lambda: sink.events)
        self.assertEqual(len(sink.events), 1)


class HomeKitEndpointTest(unittest.IsolatedAsyncioTestCase):
    async def test_bearer_and_test_events(self):
        sink = FakeSink()
        p = pipeline(tempfile.mkdtemp(), sink=sink)
        client = TestClient(TestServer(whatsapp_app(p, SECRET)))
        await client.start_server()
        self.addAsyncCleanup(client.close)
        event = {"text": "[Front Door] [Home] HomeKit: Front Door contact state changed to open", "mode": "now"}
        self.assertEqual((await client.post("/hooks/homeclaw", json=event)).status, 401)
        auth = {"Authorization": f"Bearer {SECRET}"}
        await client.post("/hooks/homeclaw", json={"text": "[HomeClaw] Webhook test event", "mode": "now"}, headers=auth)
        self.assertEqual((await client.post("/hooks/homeclaw", json=event, headers=auth)).status, 200)
        await eventually(lambda: sink.events)
        self.assertEqual([e["summary"] for e in sink.events], ["HomeKit: Front Door"])


class HomeAssistantTest(unittest.IsolatedAsyncioTestCase):
    def test_changes(self):
        from hermes_events.homeassistant import change, websocket_url
        def event(entity, old, new, name="Front door"):
            return {"data": {"entity_id": entity, "old_state": {"state": old},
                             "new_state": {"state": new, "attributes": {"friendly_name": name}}}}
        watch = ({"binary_sensor", "lock"}, {"sensor.washer"})
        self.assertEqual(change(event("binary_sensor.door", "off", "on"), *watch)[1], "Home Assistant: Front door is now on")
        self.assertIsNone(change(event("binary_sensor.door", "on", "on"), *watch))  # attributes only
        self.assertIsNone(change(event("light.kitchen", "off", "on"), *watch))  # not watched
        self.assertIsNotNone(change(event("sensor.washer", "running", "done", "Washer"), *watch))
        self.assertIsNone(change(event("lock.front", "unavailable", "unknown"), *watch))
        self.assertEqual(websocket_url("https://ha.example:8123/"), "wss://ha.example:8123/api/websocket")

    async def test_watch_against_a_fake_home_assistant(self):
        from hermes_events.homeassistant import homeassistant_watch

        async def ws(request):
            socket = web.WebSocketResponse()
            await socket.prepare(request)
            await socket.send_json({"type": "auth_required"})
            auth = await socket.receive_json()
            await socket.send_json({"type": "auth_ok" if auth["access_token"] == "t" else "auth_invalid"})
            await socket.receive_json()  # subscribe_events
            for old, new in (("off", "on"), ("on", "off")):  # the second within the cooldown
                await socket.send_json({"type": "event", "event": {"data": {
                    "entity_id": "binary_sensor.door", "old_state": {"state": old},
                    "new_state": {"state": new, "attributes": {"friendly_name": "Front door"}}}}})
            await asyncio.sleep(1)
            return socket

        app = web.Application()
        app.router.add_get("/api/websocket", ws)
        server = TestServer(app)
        await server.start_server()
        self.addAsyncCleanup(server.close)
        sink = FakeSink()
        p = pipeline(tempfile.mkdtemp(), sink=sink)
        task = asyncio.create_task(homeassistant_watch(p, str(server.make_url("")), "t", ["binary_sensor"], []))
        await eventually(lambda: sink.events)
        await asyncio.sleep(0.2)  # the second change, which the cooldown must drop
        task.cancel()
        self.assertEqual([e["summary"] for e in sink.events], ["Home Assistant: Front door is now on"])


class FakeMCP:
    def __init__(self, answers):
        self.answers = answers

    async def call(self, tool, arguments):
        return self.answers[tool]


class PollersTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sink = FakeSink()
        self.p = pipeline(self.tmp, sink=self.sink)
        self.state = pollers.State(os.path.join(self.tmp, "pollers.json"))

    async def drain(self):
        await asyncio.sleep(0.05)
        await eventually(lambda: self.sink.events, timeout=1)
        return self.sink.events

    def test_state_seeds_first(self):
        self.assertEqual(self.state.new("x", ["a", "b"]), [])
        self.assertEqual(self.state.new("x", ["a", "b", "c"]), ["c"])
        self.state.save()
        self.assertEqual(pollers.State(self.state.path).new("x", ["c", "d"]), ["d"])

    async def test_calendar(self):
        soon = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 600))
        later = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 86400))
        dinner = {"@type": "Event", "identifier": "E1", "name": "Dinner", "startDate": later}
        imcp = FakeMCP({"events_fetch": [dinner]})
        await pollers.calendar(self.p, self.state, imcp)  # seeds
        imcp.answers["events_fetch"] = [dinner, {"identifier": "E2", "name": "Drink", "startDate": soon, "location": "Bobbolitas"}]
        await pollers.calendar(self.p, self.state, imcp)
        summaries = [e["summary"] for e in await self.drain()]
        self.assertEqual(sorted(summaries), ["New event in the calendar: Drink", "Starting soon: Drink"])

    async def test_calls(self):
        db = os.path.join(self.tmp, "CallHistory.storedata")
        with sqlite3.connect(db) as c:
            c.execute("CREATE TABLE ZCALLRECORD (Z_PK INTEGER, ZDATE REAL, ZADDRESS TEXT, ZNAME TEXT, ZANSWERED INTEGER, ZORIGINATED INTEGER)")
            c.execute("INSERT INTO ZCALLRECORD VALUES (1, 0, '+33611111111', 'Zoé', 0, 0)")
        await pollers.calls(self.p, self.state, db)
        with sqlite3.connect(db) as c:
            c.execute("INSERT INTO ZCALLRECORD VALUES (2, 0, '+33622222222', 'Léa', 0, 0)")
            c.execute("INSERT INTO ZCALLRECORD VALUES (3, 0, '+33633333333', 'Out', 1, 1)")
        await pollers.calls(self.p, self.state, db)
        self.assertEqual([e["summary"] for e in await self.drain()], ["Missed call from Léa"])

    async def test_files(self):
        folder = os.path.join(self.tmp, "Downloads")
        os.makedirs(folder)
        await pollers.files(self.p, self.state, [folder])
        for name in ("invoice.pdf", ".DS_Store", "big.crdownload"):
            open(os.path.join(folder, name), "w").close()
        await pollers.files(self.p, self.state, [folder])
        self.assertEqual([e["summary"] for e in await self.drain()], ["New file: invoice.pdf"])

    async def test_health_transitions(self):
        health = pollers.Health()
        for ok in (False, False, False, True, True):
            health.report(self.p, "uzu", ok)
        self.assertEqual([e["text"] for e in await self.drain()], ["⚠️ uzu is not answering.", "✅ uzu is back."])

    def test_an_empty_first_answer_records_nothing(self):
        self.assertEqual(self.state.new("mail", [], wait_for_data=True), [])
        self.assertEqual(self.state.new("mail", ["m1"], wait_for_data=True), [])  # still the first real answer
        self.assertEqual(self.state.new("mail", ["m1", "m2"], wait_for_data=True), ["m2"])

    async def test_logins_do_not_repeat_at_logout(self):
        lines = ["arthur  ttys000  192.168.1.20  Wed Oct 28 15:00   still logged in"]

        async def fake_run(*command, timeout=60):
            if command[0].endswith("last"):
                return "\n".join(lines)
            return "Now drawing from 'AC Power'"

        original, pollers.run = pollers.run, fake_run
        try:
            health = pollers.Health()
            await pollers.system(self.p, self.state, health, {})  # seeds
            lines.insert(0, "arthur  ttys001  10.0.0.5  Wed Oct 28 16:00   still logged in")
            lines[1] = "arthur  ttys000  192.168.1.20  Wed Oct 28 15:00 - 15:42  (00:42)"
            await pollers.system(self.p, self.state, health, {})
        finally:
            pollers.run = original
        # (The disk check is this machine's real one: count logins only.)
        texts = [e["text"] for e in await self.drain() if e["key"].startswith("system:login:")]
        self.assertEqual(len(texts), 1)
        self.assertIn("10.0.0.5", texts[0])

    def test_items(self):
        self.assertEqual(pollers.items({"events": [{"id": 1}]}), [{"id": 1}])
        self.assertEqual(pollers.items([{"id": 1}, "x"]), [{"id": 1}])


def ig_thread(items, viewer="1", is_group=False, users=None, title=""):
    """A thread as Instagram's API answers it: newest item first, microseconds."""
    return {"thread_id": "340282366841710300949128", "viewer_id": viewer, "is_group": is_group, "thread_title": title,
            "users": users or [{"pk": 2, "username": "zoe.martin", "full_name": "Zoé"}],
            "items": [{"item_id": f"i{n}", "user_id": int(u), "timestamp": str(int(t * 1e6)), "item_type": "text", "text": x}
                      for n, (u, t, x) in enumerate(reversed(items))]}


class HistoryTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp()

    def fake(self, name, output):
        """An executable printing `output` and keeping its arguments."""
        path = os.path.join(self.tmp, name)
        with open(path + ".out", "w") as f:
            f.write(output)
        with open(path, "w") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{path}.args"\ncat "{path}.out"\n')
        os.chmod(path, 0o755)
        return path

    def args(self, path):
        with open(path + ".args") as f:
            return f.read().split("\n")

    def test_parsers(self):
        wacli = {"success": True, "data": {"messages": [
            {"MsgID": "N1", "Timestamp": ISO_NOW, "FromMe": False, "SenderName": "Zoé", "Text": "new one"},
            {"MsgID": "E2", "Timestamp": "2026-11-04T10:01:00Z", "FromMe": True, "Text": "ok pour demain"},
            {"MsgID": "E1", "Timestamp": "2026-11-04T10:00:00Z", "FromMe": False, "SenderName": "Zoé", "Text": "on se voit ?"},
            {"MsgID": "R", "Timestamp": "2026-11-04T10:02:00Z", "ReactionToID": "E2", "ReactionEmoji": "👍"},
            {"MsgID": "P", "Timestamp": "2026-11-04T10:03:00Z", "MediaType": "image", "MediaCaption": "là"}]}}
        earlier = whatsapp_earlier(wacli, {"N1"})
        self.assertEqual([(m.sender, m.text) for m in earlier],
                         [("Zoé", "on se voit ?"), ("me", "ok pour demain"), ("them", "[image] là")])
        lines = "\n".join(json.dumps(m) for m in [
            {"guid": "B", "created_at": "2026-11-04T10:01:00Z", "is_from_me": True, "text": "oui"},
            {"guid": "A", "created_at": "2026-11-04T10:00:00Z", "sender": "+336", "sender_name": "Léa", "text": "samedi ?"},
            {"guid": "C", "created_at": "2026-11-04T10:02:00Z", "is_reaction": True, "text": "Loved"}])
        self.assertEqual([(m.sender, m.text) for m in imessage_earlier(lines + "\nnot json", set())],
                         [("Léa", "samedi ?"), ("me", "oui")])

    async def test_commands(self):
        out = {"data": {"messages": [{"MsgID": "E1", "Timestamp": ISO_NOW, "FromMe": True, "Text": "à 19h ?"}]}}
        wacli = self.fake("wacli", json.dumps(out))
        imsg = self.fake("imsg", json.dumps({"guid": "A", "created_at": ISO_NOW, "is_from_me": False,
                                             "sender_name": "Léa", "text": "samedi ?"}))
        history = History(wacli=[wacli, "--store", "/s"], imsg=[imsg], limit=5)
        new = [Message("N1", NOW + 60, "Zoé", "ok")]
        context = await history(Chat("whatsapp", "336@s.whatsapp.net", "Zoé"), new)
        self.assertEqual([(m.sender, m.text) for m in context.earlier], [("me", "à 19h ?")])
        args = self.args(wacli)
        self.assertEqual(args[:3], ["--store", "/s", "--json"])
        self.assertIn("--read-only", args)
        self.assertEqual(args[args.index("--chat") + 1], "336@s.whatsapp.net")
        self.assertEqual(args[args.index("--limit") + 1], "5")
        context = await history(Chat("imessage", "7", "Léa"), new)
        self.assertEqual(context.earlier[0].text, "samedi ?")
        self.assertEqual(self.args(imsg)[:3], ["history", "--chat-id", "7"])
        self.assertIsNone(await history(Chat("discord", "x", "x"), new))
        # Older than a week: not context.
        old = History(wacli=[wacli], clock=lambda: NOW + 30 * 86400)
        self.assertEqual((await old(Chat("whatsapp", "j", "M"), new)).earlier, [])

    async def test_pipeline_puts_it_in_the_event(self):
        sink, triage = FakeSink(), FakeTriage()

        async def history(chat, messages):
            return Context([Message("e", NOW - 120, "me", "on se fait un ciné ?")])

        p = pipeline(self.tmp, triage=triage, sink=sink)
        p.history = history
        chat, message, _ = whatsapp_message(wa("à quelle heure ?"))
        p.message(chat, message)
        await eventually(lambda: sink.events)
        event = sink.events[0]
        self.assertIn("me: on se fait un ciné ?", event["context"])
        self.assertIn("Zoé: à quelle heure ?", event["messages"])
        self.assertNotIn("ciné", event["messages"])
        self.assertIn("ciné", UzuTriage("u", "m").request(triage.events[0][0])["messages"][1]["content"])
        # The small model gets the last lines only.
        long = {**event, "context": "Earlier:\n" + "\n".join(f"[1{i}:00] me: m{i}" for i in range(10)) + "\n\nThe new messages:"}
        content = UzuTriage("u", "m").request(long)["messages"][1]["content"]
        self.assertNotIn("m3", content)
        self.assertIn("m9", content)
        self.assertIn("The new messages:\n[", content)
        # A notice has no conversation, but the field the route's prompt names.
        p.notice("calendar", "x", "Soon: dentist", id="c1")
        await eventually(lambda: len(sink.events) == 2)
        self.assertEqual(sink.events[1]["context"], "")

    async def test_a_failing_history_or_an_answer(self):
        sink = FakeSink()

        async def broken(chat, messages):
            raise RuntimeError("wacli exited 1")

        p = pipeline(self.tmp, sink=sink)
        p.history = broken
        chat, message, _ = whatsapp_message(wa("tu es là ?"))
        p.message(chat, message)
        await eventually(lambda: sink.events)
        self.assertEqual((len(sink.events), sink.events[0]["context"]), (1, ""))

        async def answered(chat, messages):
            return Context([], answered=True)

        p.history = answered
        chat, message, _ = whatsapp_message(wa("et demain ?", id="A9"))
        p.message(chat, message)
        await asyncio.sleep(0.2)
        self.assertEqual(len(sink.events), 1)


class InstagramThreadTest(unittest.IsolatedAsyncioTestCase):
    def test_thread_and_its_context(self):
        thread = Thread.parse(ig_thread([("2", NOW - 3600, "tu viens ce soir ?"), ("1", NOW - 3500, "oui"),
                                         ("2", NOW - 5, "On se voit toujours à 20 h ?")]))
        self.assertEqual((thread.id, thread.name, thread.is_group), ("340282366841710300949128", "Zoé", False))
        self.assertEqual([m.sender for m in thread.items], ["Zoé", "me", "Zoé"])
        self.assertEqual(thread.sender_of("On se voit toujours à 20 h ?"), "Zoé")
        new = [Message("n", NOW, "?", "On se voit toujours à 20 h ?")]
        context = thread.context(new, 10, NOW - 86400)
        self.assertEqual([m.text for m in context.earlier], ["tu viens ce soir ?", "oui"])
        self.assertFalse(context.answered)
        answered = Thread.parse(ig_thread([("2", NOW - 5, "tu es là ?"), ("1", NOW - 2, "oui")]))
        self.assertTrue(answered.context([Message("n", NOW, "?", "tu es là ?")], 10, 0).answered)
        group = Thread.parse(ig_thread([("2", NOW, "x"), ("3", NOW, "salut")], is_group=True, title="Les potes",
                                       users=[{"pk": 2, "username": "a"}, {"pk": 3, "username": "b", "full_name": "Bea"}]))
        self.assertEqual((group.name, group.sender_of("salut"), group.sender_of("nope")), ("Les potes", "Bea", None))

    def test_thread_id_in_the_uri(self):
        def payload(uri):
            return {"data": json.dumps({"uri": uri, "notifType": "direct_v2_message"})}
        self.assertEqual(thread_id_of(payload("direct_v2?id=340282366841710300949128&x=29")), "340282366841710300949128")
        self.assertEqual(thread_id_of(payload("https://www.instagram.com/direct/t/1234567890/")), "1234567890")
        self.assertIsNone(thread_id_of(payload("https://www.instagram.com/stories/x/")))
        self.assertIsNone(thread_id_of({"data": "not json"}))

    async def test_resolve(self):
        thread = Thread.parse(ig_thread([("2", NOW - 5, "pas question")]))

        class Fake:
            def __init__(self, found):
                self.found, self.asked = found, []

            async def thread(self, tid):
                self.asked.append(("thread", tid))
                return self.found

            async def find(self, text):
                self.asked.append(("find", text))
                return self.found

        got = []

        class P:
            def message(self, chat, message):
                got.append((chat, message))

        chat, message = instagram_message({"title": "Instagram", "body": "pas question", "host": "www.instagram.com"}, NOW)
        fake = Fake(thread)
        await resolve_instagram(fake, P(), {"data": "{}"}, chat, message)
        self.assertEqual(fake.asked, [("find", "pas question")])
        self.assertEqual((got[0][0].key, got[0][0].name, got[0][1].sender),
                         ("instagram:340282366841710300949128", "Zoé", "Zoé"))
        # Not found: the notification as it is.
        await resolve_instagram(Fake(None), P(), {"data": json.dumps({"uri": "direct_v2?id=12345678"})}, chat, message)
        self.assertEqual((got[1][0].key, got[1][1].sender), ("instagram:instagram", message.sender))

    async def test_api_through_a_tab(self):
        calls = []

        class FakeCDP:
            async def call(self, method, params=None, session=None):
                calls.append(method)
                if method == "Target.createTarget":
                    return {"result": {"targetId": "T"}}
                if method == "Target.attachToTarget":
                    return {"result": {"sessionId": "S"}}
                if method == "Runtime.evaluate" and params["expression"] == "location.origin":
                    return {"result": {"result": {"value": "https://www.instagram.com"}}}
                if method == "Runtime.evaluate":
                    self.expression = params["expression"]
                    return {"result": {"result": {"value": [json.dumps({"thread": ig_thread([("2", NOW, "yo")])})]}}}
                return {"result": {}}

        ig = Instagram()
        self.assertIsNone(await ig.thread("123"))  # not connected yet
        ig.cdp = FakeCDP()
        thread = await ig.thread("340282366841710300949128")
        self.assertEqual(thread.items[0].text, "yo")
        self.assertIn("/api/v1/direct_v2/threads/340282366841710300949128/", ig.cdp.expression)
        self.assertNotIn("seen", ig.cdp.expression)
        self.assertEqual(calls[-1], "Target.closeTarget")
        self.assertIsNone(await ig.thread("1; alert(1)"))



class DiscordTest(unittest.IsolatedAsyncioTestCase):
    async def test_logged_out_is_said_once(self):
        tmp = tempfile.mkdtemp()
        sink = FakeSink()
        p = pipeline(tmp, sink=sink)
        url = {"now": "https://discord.com/channels/@me"}

        class FakeCDP:
            async def call(self, method, params=None, session=None):
                if method == "Target.getTargets":
                    return {"result": {"targetInfos": [{"targetId": "D", "url": url["now"]}]}}
                if method == "Target.createTarget":
                    return {"result": {"targetId": "D"}}
                if method == "Target.attachToTarget":
                    return {"result": {"sessionId": "S"}}
                return {"result": {}}

        task = asyncio.create_task(keep_discord(FakeCDP(), "https://discord.com/channels/@me", every=0.01, pipeline=p))
        await asyncio.sleep(0.05)
        self.assertEqual(sink.events, [])
        url["now"] = "https://discord.com/login?redirect_to=%2Fchannels%2F%40me"
        await eventually(lambda: sink.events)
        await asyncio.sleep(0.05)
        task.cancel()
        self.assertEqual([e["key"] for e in sink.events], ["system:discord-logged-out"])
        self.assertIn("logged out", sink.events[0]["text"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
