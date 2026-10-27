"""unii: one chat that never ends, and sub-chats kept out of it.

See README.md. Registered as a general Hermes plugin
(https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/features/plugins.md)
so the context engine can use ctx.llm for its compactions.
"""

from __future__ import annotations

import json
import logging
import os

logger = logging.getLogger(__name__)


def _config(home: str) -> dict:
    try:
        with open(os.path.join(home, "unii", "config.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def _complete(ctx, config: dict):
    """The compaction call: the main model, or `compaction_model` ("provider:model")."""
    pinned = {}
    if model := config.get("compaction_model"):
        provider, _, name = model.partition(":")
        if provider == "uzu" and name in ("", "local"):
            name = config.get("uzu_model", "")
        pinned = {"provider": provider, "model": name}

    def complete(messages):
        result = ctx.llm.complete(
            messages=messages,
            max_tokens=600,
            temperature=0.2,
            purpose="unii.compaction",
            **pinned,
        )
        return result.text or ""

    return complete


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    from .commands import SubCommand
    from .engine import UniiEngine
    from .hooks import Hooks, register_sweeper
    from .runtime import Runtime

    home = str(get_hermes_home())
    config = _config(home)
    runtime = Runtime(home, config, _complete(ctx, config))
    hooks = Hooks(runtime)

    ctx.register_context_engine(UniiEngine(runtime))
    ctx.register_hook("pre_gateway_dispatch", hooks.pre_gateway_dispatch)
    ctx.register_hook("pre_tool_call", hooks.pre_tool_call)
    ctx.register_command(
        "sub",
        SubCommand(runtime),
        description="Sub-chat policy: memory, volume, tools, expiry, encryption, model",
        args_hint="[preset|set|unlock|lock|end|presets] …",
    )
    register_sweeper(hooks)
    logger.info("unii: memory in %s", runtime.root)
