"""unii: one chat that never ends, and sub-chats kept out of it.

See README.md. Registered as a general Hermes plugin
(https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/features/plugins.md)
so the context engine can use ctx.llm for its compactions.
"""

from __future__ import annotations

import json
import logging
import os
import sys

logger = logging.getLogger(__name__)


def _config(home: str) -> dict:
    try:
        with open(os.path.join(home, "unii", "config.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def _shared_state() -> dict:
    """One runtime per process. Hermes imports this package twice: as a general
    plugin, and again under another module name when it resolves
    `context.engine` (plugins/context_engine/__init__.py, load_context_engine,
    with a no-op context). Module globals would give each its own volumes,
    keys and gateway handles, so the state hangs off `sys` instead."""
    return sys.__dict__.setdefault("_hermes_unii_state", {"runtime": None, "llm_ctx": None})


def _is_real_context(ctx) -> bool:
    """The engine loader's context only collects the engine; its llm and hooks do nothing."""
    try:
        from plugins.plugin_loader import NoopPluginContext
    except Exception:
        return True
    return not isinstance(ctx, NoopPluginContext)


def _complete(state: dict, config: dict):
    """The compaction call, on the main model or `compaction_model` ("provider:model")."""
    pinned = {}
    if model := config.get("compaction_model"):
        provider, _, name = model.partition(":")
        if provider == "uzu" and name in ("", "local"):
            name = config.get("uzu_model", "")
        pinned = {"provider": provider, "model": name}

    def complete(messages):
        ctx = state["llm_ctx"]
        if ctx is None:
            raise RuntimeError("unii: no plugin context with LLM access yet")
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

    state = _shared_state()
    real = _is_real_context(ctx)
    if real:
        state["llm_ctx"] = ctx

    runtime = state["runtime"]
    first = runtime is None
    if first:
        home = str(get_hermes_home())
        config = _config(home)
        runtime = Runtime(home, config, _complete(state, config))
        state["runtime"] = runtime
        state["hooks"] = Hooks(runtime)
        register_sweeper(state["hooks"])
        logger.info("unii: memory in %s", runtime.root)

    ctx.register_context_engine(UniiEngine(runtime))
    if real:
        hooks = state["hooks"]
        ctx.register_hook("pre_gateway_dispatch", hooks.pre_gateway_dispatch)
        ctx.register_hook("post_gateway_admission", hooks.post_gateway_admission)
        ctx.register_hook("pre_tool_call", hooks.pre_tool_call)
        ctx.register_hook("on_session_reset", hooks.on_session_reset)
        ctx.register_command(
            "sub",
            SubCommand(runtime),
            description="Sub-chat policy: memory, volume, tools, expiry, encryption, model",
            args_hint="[preset|set|unlock|lock|end|presets] …",
        )
