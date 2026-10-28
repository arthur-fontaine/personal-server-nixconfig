"""`python -m hermes_events <config.json>`: the config comes from Nix
(modules/hermes/agent/events.nix), the secrets from the secrets file."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

from aiohttp import web

from .core import Pipeline, Seen
from .hermes import HermesSink
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
        max_age_seconds=config["max_age_seconds"],
    )
    sources = config["sources"]
    tasks = []
    if sources.get("whatsapp", {}).get("enabled"):
        runner = web.AppRunner(whatsapp_app(pipeline, secret))
        await runner.setup()
        await web.TCPSite(runner, config["listen"]["host"], config["listen"]["port"]).start()
    if sources.get("imessage", {}).get("enabled"):
        tasks.append(asyncio.create_task(imessage_watch(pipeline, sources["imessage"]["command"])))
    logging.getLogger("hermes_events").info("listening: %s", ", ".join(k for k, v in sources.items() if v.get("enabled")))
    await asyncio.gather(*tasks, asyncio.Event().wait())


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with open(sys.argv[1]) as f:
        asyncio.run(main(json.load(f)))
