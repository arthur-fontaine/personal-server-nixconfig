"""`python -m hermes_events <config.json>`: the config comes from Nix
(modules/hermes/agent/events.nix), the secrets from the secrets file."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

from aiohttp import web

from . import pollers
from .core import Pipeline, Seen
from .hermes import HermesSink
from .browser import instagram_watch
from .sources import imessage_watch, whatsapp_app
from .triage import UzuTriage


def read_env_file(path: str) -> dict[str, str]:
    values = {}
    with open(path) as f:
        for line in f:
            name, sep, value = line.strip().partition("=")
            if sep and not name.startswith("#"):
                values[name] = value
    return values


async def main(config: dict) -> None:
    secrets = read_env_file(config["secrets_file"])
    secret = secrets.get("WEBHOOK_SECRET", "")
    if not secret:
        raise SystemExit("no WEBHOOK_SECRET in the secrets file: run scripts/bootstrap-macos.sh")
    owner = secrets.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()

    pipeline = Pipeline(
        triage=UzuTriage(config["triage"]["url"], config["triage"]["model"], config["triage"]["timeout"]),
        sink=HermesSink(config["hermes_url"], secret, owner),
        seen=Seen(os.path.join(config["state_dir"], "seen.json")),
        batch_seconds=config["batch_seconds"],
        max_batch_seconds=config["max_batch_seconds"],
        max_age_seconds=config["max_age_seconds"],
    )
    sources = config["sources"]
    on = lambda name: sources.get(name, {}).get("enabled")
    tasks = []
    # WhatsApp and HomeKit post here.
    runner = web.AppRunner(whatsapp_app(pipeline, secret))
    await runner.setup()
    await web.TCPSite(runner, config["listen"]["host"], config["listen"]["port"]).start()
    if on("imessage"):
        tasks.append(asyncio.create_task(imessage_watch(pipeline, sources["imessage"]["command"])))
    if on("instagram") or on("discord"):
        tasks.append(asyncio.create_task(instagram_watch(
            pipeline, sources["instagram"]["devtools"],
            discord=sources["discord"]["url"] if on("discord") else None)))

    state = pollers.State(os.path.join(config["state_dir"], "pollers.json"))
    imcp = pollers.MCP(config.get("imcp_command", []))
    polls = {
        "calendar": lambda c: pollers.calendar(pipeline, state, imcp, c.get("lead_minutes", 30)),
        "mail": lambda c: pollers.mail(pipeline, state, imcp),
        "reminders": lambda c: pollers.reminders(pipeline, state, c["command"]),
        "calls": lambda c: pollers.calls(pipeline, state, os.path.expanduser(c["database"])),
        "files": lambda c: pollers.files(pipeline, state, c["folders"]),
        "github": lambda c: pollers.github(pipeline, state, c["command"], secrets["GITHUB_NOTIFICATIONS_TOKEN"]),
        "runpod": lambda c: pollers.runpod(pipeline, state, secrets.get("RUNPOD_API_KEY", "")),
    }
    if on("github") and not secrets.get("GITHUB_NOTIFICATIONS_TOKEN"):
        logging.getLogger("hermes_events").info("github: no GITHUB_NOTIFICATIONS_TOKEN in the secrets file, skipped")
        sources["github"]["enabled"] = False
    for name, poll in polls.items():
        if on(name):
            c = sources[name]
            tasks.append(asyncio.create_task(pollers.every(c.get("every", 300), name, lambda p=poll, c=c: p(c), state)))
    if on("system"):
        health = pollers.Health()
        c = sources["system"]
        tasks.append(asyncio.create_task(pollers.every(
            c.get("every", 300), "system", lambda: pollers.system(pipeline, state, health, c["services"]), state)))
    logging.getLogger("hermes_events").info("listening: %s", ", ".join(k for k, v in sources.items() if v.get("enabled")))
    await asyncio.gather(*tasks, asyncio.Event().wait())


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with open(sys.argv[1]) as f:
        asyncio.run(main(json.load(f)))
