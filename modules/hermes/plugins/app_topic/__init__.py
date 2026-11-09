"""app_topic: Hermes' side of the owner's iOS app (docs/app.md, docs/app-protocol.md).

The app is a Telegram client of the owner's DM with the bot. Machine traffic
goes through a hidden forum topic "App" of that DM: the state the app shows
(agent status, open questions, the pet, sub-chats, machine and model stats,
devices), the notifications' spoken text, and the app's requests. This
plugin keeps that topic, counts model usage, keeps the pet's mood, makes
call turns speakable, and gives Hermes the tools for pets and big files.

Other plugins may report an approval's plain-language summary before the card
is sent (sys.modules["app_topic"].approval_summary(command, summary)), and
owner_approval reports its own questions (question_card / question_done).
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path

logger = logging.getLogger("app_topic")

STATE: dict = {"app": None, "ctx": None}

PET_SCHEMA = {
    "name": "pet_generate",
    "description": (
        "Hatch a new pet for the owner's app: an animated mascot (Codex pet format) drawn by the image "
        "provider from a description, which becomes the current pet and the app's icon. Takes a few "
        "minutes and one to four image generations, within a per-pet budget (it answers what it spent): in "
        "the main chat, hand it to a background subagent. Afterwards, decide whether to reinstall the app (sideload_install with app \"hermes\") so the icon "
        "follows."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "description": {"type": "string", "description": "What the pet looks like (an original character)."},
            "name": {"type": "string", "description": "Its name (optional)."},
        },
        "required": ["description"],
    },
}

REDRAW_SCHEMA = {
    "name": "pet_redraw",
    "description": (
        "Redraw some animation rows of the current pet, keeping the rest of its sheet: one image per row, "
        "within the per-pet budget (it answers what it spent). Rows: idle, running-right, running-left, waving, "
        "jumping, failed, waiting, running (Hermes working), review (Hermes thinking). Use it when the owner "
        "dislikes how one animation looks."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "rows": {"type": "array", "items": {"type": "string"}, "description": "The rows to redraw."},
        },
        "required": ["rows"],
    },
}

FETCH_SCHEMA = {
    "name": "bigfile_fetch",
    "description": (
        "Download files the owner sent as [fichier: <url>] links (gofile.io, SwissTransfer, or any direct "
        "link) into ~/.hermes/files. Pass the link, or the whole message to take every link in it."
    ),
    "parameters": {"type": "object", "properties": {
        "url": {"type": "string", "description": "A link, or text containing [fichier: …] links."}},
        "required": ["url"]},
}

SEND_SCHEMA = {
    "name": "bigfile_send",
    "description": (
        "Share a file too big for Telegram (the bot sends at most 50 MB): uploads it to gofile.io and "
        "returns a [fichier: <url>] line to put, alone, at the end of your reply; the app shows it as a "
        "file card. Under 50 MB, attach it with MEDIA:<path> instead."
    ),
    "parameters": {"type": "object", "properties": {
        "path": {"type": "string", "description": "Absolute path of the file to share."}},
        "required": ["path"]},
}


def _config(home: Path) -> dict:
    try:
        return json.loads((home / "app_topic" / "config.json").read_text())
    except (OSError, ValueError):
        return {}


def approval_summary(command: str, summary: str) -> None:
    app = STATE["app"]
    if app is not None and command and summary:
        app.questions.add_summary(command, summary)


def pre_approval_request(command: str = "", description: str = "", **_) -> None:
    """guard (guard/titles.py) leads each card it escalates with a plain
    sentence, the raw action under it; Hermes' own pattern cards have
    neither (their description is the pattern's name), and stay without."""
    guard = sys.modules.get("guard")
    summarize = getattr(guard, "card_summary", None)
    detail_of = getattr(guard, "card_detail", None)
    app = STATE["app"]
    if summarize is None or not command or app is None:
        return
    try:
        summary = summarize(description)
        detail = detail_of(description) if detail_of else None
    except Exception:
        summary = detail = None
    app.questions.add_summary(command, summary, detail)


CALL_MARK = "\U0001f399"
CALL_CONTEXT = (
    "[This message was spoken in a call from the user's app, and your answer is read aloud as it streams. "
    "Answer as on the phone: open with one short sentence that answers or says what you will do, then short "
    "spoken sentences; no markdown, lists, tables, links, code or emoji; numbers and symbols as words. "
    "Before a long step, say so in a sentence first. What is better read than heard (links, code, lists, "
    "figures to keep) goes after your spoken answer, under a line starting with \U0001f4ce: it is sent as a "
    "separate written message, never read aloud; never mix the two.]"
)


def call_turn(user_message=None, platform="", **_):
    """pre_llm_call: a call turn (docs/app-protocol.md §6) gets the spoken style
    with its message, not in the system prompt, so the prompt cache holds.
    While the app says a call is on (call.state), every Telegram turn does."""
    text = user_message if isinstance(user_message, str) else ""
    app = STATE["app"]
    if text.lstrip().startswith(CALL_MARK) or (app is not None and app.call_active() and platform == "telegram"):
        return {"context": CALL_CONTEXT}
    return None


def question_card(chat_id, thread, message_id, text_html, markup, command=None, summary=None) -> None:
    app = STATE["app"]
    if app is not None:
        app.on_card(chat_id, thread, message_id, text_html, markup, command=command, summary=summary)


def question_done(chat_id, message_id) -> None:
    app = STATE["app"]
    if app is not None:
        app.questions.resolve(chat=app.topic_of(chat_id, ""), message_id=int(message_id))


def _pet_generate(args: dict, **_) -> str:
    from .app import ProviderRefused, generate_pet, spent

    app = STATE["app"]
    description = str((args or {}).get("description") or "").strip()
    if not description:
        return json.dumps({"error": "description is required"})
    if app.pet_busy:
        return json.dumps({"error": "a pet is already being generated"})
    app.pet_busy = True
    try:
        result = generate_pet(description, (args or {}).get("name"), app.pet_max_cost())
        manifest = app.adopt_pet(result["slug"], Path(result["directory"]))
    except ProviderRefused as error:
        return json.dumps({"error": str(error), "retry": False, "spent": spent(error.report),
                           "note": "Do not call pet_generate again until the owner fixed this: tell them, in their "
                                   "words, what happened and what they can do."})
    except Exception as error:
        report = getattr(error, "report", None) or {}
        return json.dumps({"error": f"generation failed: {error}", "spent": spent(report),
                           "rows_redrawn": report.get("repaired_rows"),
                           "note": "Tell the owner what it cost; another try costs as much again."})
    finally:
        app.pet_busy = False
    report = result.get("report") or {}
    return json.dumps({"ok": True, "pet": manifest, "files": str(app.dir / "pet"), "spent": spent(report),
                       "path": report.get("path"), "rows_redrawn": report.get("repaired_rows"),
                       "note": "The app shows it at once; its icon changes only when the app is rebuilt "
                               "(sideload_install with app \"hermes\"), which you may decide to do now or later."})


def _pet_redraw(args: dict, **_) -> str:
    from .app import ProviderRefused, redraw_pet_rows, spent

    app = STATE["app"]
    rows = [str(r).strip() for r in (args or {}).get("rows") or [] if str(r).strip()]
    slug = app.pet.data["slug"]
    if not slug:
        return json.dumps({"error": "there is no current pet"})
    if app.pet_busy:
        return json.dumps({"error": "a pet is already being generated"})
    app.pet_busy = True
    try:
        result = redraw_pet_rows(slug, rows, app.pet_max_cost())
        manifest = app.adopt_pet(result["slug"], Path(result["directory"]), redrawn=True)
    except ProviderRefused as error:
        return json.dumps({"error": str(error), "retry": False, "spent": spent(error.report)})
    except Exception as error:
        report = getattr(error, "report", None) or {}
        return json.dumps({"error": f"redraw failed: {error}", "spent": spent(report)})
    finally:
        app.pet_busy = False
    return json.dumps({"ok": True, "pet": manifest, "rows_redrawn": rows, "spent": spent(result.get("report")),
                       "note": "The app shows the new rows at once."})


def _bigfile_fetch(args: dict, **_) -> str:
    from . import bigfiles

    app = STATE["app"]
    raw = str((args or {}).get("url") or "").strip()
    urls = bigfiles.links(raw) or ([raw] if raw.startswith("http") else [])
    if not urls:
        return json.dumps({"error": "no link"})
    target = Path.home() / ".hermes" / "files"
    gofile = bigfiles.Gofile(app.dir / "gofile.json")
    token = os.environ.get(app.config.get("big_files", {}).get("swisstransfer_token_env") or "INFOMANIAK_TOKEN")
    out, errors = [], []
    for url in urls:
        try:
            out += [str(p) for p in bigfiles.fetch(url, target, gofile, token or None)]
        except Exception as error:
            errors.append(f"{url}: {error}")
    return json.dumps({"files": out, "errors": errors}, ensure_ascii=False)


def _bigfile_send(args: dict, **_) -> str:
    from . import bigfiles

    app = STATE["app"]
    path = Path(str((args or {}).get("path") or "")).expanduser()
    if not path.is_file():
        return json.dumps({"error": f"no file at {path}"})
    try:
        url = bigfiles.Gofile(app.dir / "gofile.json").upload(path)
    except Exception as error:
        return json.dumps({"error": f"upload failed: {error}"})
    return json.dumps({"link": url, "line": f"[fichier: {url}]",
                       "note": "Put the line alone at the end of your reply."})


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    from .app import App

    sys.modules.setdefault("app_topic", sys.modules[__name__])
    if STATE["app"] is None:
        home = Path(get_hermes_home())
        STATE["app"] = App(home, _config(home))
    app = STATE["app"]
    STATE["ctx"] = ctx
    status = app.status

    ctx.register_telegram_handler(app.attach)
    ctx.register_hook("pre_gateway_dispatch", lambda event=None, **kw: app.dispatch(event))
    ctx.register_hook("pre_llm_call", status.begin)
    ctx.register_hook("pre_api_request", status.pre_api_request)
    ctx.register_hook("pre_tool_call", status.pre_tool_call)
    ctx.register_hook("post_tool_call", status.post_tool_call)
    ctx.register_hook("on_human_input_request",
                      lambda session_id="", **kw: status.human_input(session_id, True))

    def resolved(session_id="", **kw):
        status.human_input(session_id, False)
        app.human_input_resolved(**kw)

    ctx.register_hook("on_human_input_resolved", resolved)
    ctx.register_hook("on_session_end", status.end)
    ctx.register_hook("pre_approval_request", pre_approval_request)
    ctx.register_hook("pre_llm_call", call_turn)
    ctx.register_hook("pre_llm_call", app.taken)
    ctx.register_hook("pre_api_request", app.taken)
    ctx.register_hook("post_api_request", app.post_api_request)
    ctx.register_hook("api_request_error", app.api_request_error)
    ctx.register_hook("post_auxiliary_call", app.post_auxiliary_call)

    pets = app.config.get("pets") or {}
    if pets.get("enable", True):
        ctx.register_tool(name="pet_generate", toolset="app", schema=PET_SCHEMA, handler=_pet_generate)
        ctx.register_tool(name="pet_redraw", toolset="app", schema=REDRAW_SCHEMA, handler=_pet_redraw)
    ctx.register_tool(name="bigfile_fetch", toolset="app", schema=FETCH_SCHEMA, handler=_bigfile_fetch)
    ctx.register_tool(name="bigfile_send", toolset="app", schema=SEND_SCHEMA, handler=_bigfile_send)

    from .push import Push

    push = Push(app.config.get("apns") or {}, app.dir / "push.json")
    app.extra_handlers["push.register"] = push.register
    app.extra_handlers["push.unregister"] = push.unregister
    if push.enabled:
        app.extra_handlers["_push_notify"] = push.notify
        app.extra_handlers["_push_activity"] = push.activity

    try:
        app.sync_pet()
    except Exception:
        logger.debug("app_topic: pet not synced at start", exc_info=True)
