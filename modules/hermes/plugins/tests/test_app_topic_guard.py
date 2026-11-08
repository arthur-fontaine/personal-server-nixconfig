"""app_topic with the real guard, both loaded by Hermes' plugin loader: the
App topic's permission-mode control follows guard's mode and /mode, and an
approval card guard escalates carries guard's bash title as
``question.summary`` (the card rendered by Hermes' Telegram adapter, the
hook fired by Hermes' approval context). The title comes from guard's disk
cache, so no model is called."""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

PLUGINS = Path(__file__).resolve().parent.parent

LONG = "cd ~/workspace/site && rm -rf build node_modules/.cache && npm ci && npm run build -- --mode production"
TITLE = "Rebuilds the site from a clean state"
SHORT = "touch ~/workspace/notes.txt"


class Button:
    def __init__(self, text: str, callback_data: str) -> None:
        self.text, self.callback_data = text, callback_data


class Markup:
    def __init__(self, rows) -> None:
        self.inline_keyboard = rows


def card(n: int) -> Markup:
    return Markup([[Button("Once", f"ea:once:{n}"), Button("Deny", f"ea:deny:{n}")]])


def main() -> None:
    home = Path(tempfile.mkdtemp())
    try:
        hermes_home = home / ".hermes"
        os.environ.update(HOME=str(home), HERMES_HOME=str(hermes_home), TELEGRAM_ALLOWED_USERS="4242")
        for name in ("guard", "app_topic"):
            shutil.copytree(PLUGINS / name, hermes_home / "plugins" / name)
        (hermes_home / "guard").mkdir()
        # No review model: ask mode asks for every action without a model call.
        (hermes_home / "guard" / "config.json").write_text(json.dumps({
            "mode": "ask", "cwd": str(home / "workspace"), "trusted_platforms": ["telegram"]}))
        (hermes_home / "app_topic").mkdir()
        (hermes_home / "app_topic" / "config.json").write_text(json.dumps({
            "chain": [{"provider": "p", "model": "m"}], "delivery_cli": "/nonexistent/hermes-app",
            "presets": [], "pets": {"enable": False}}))
        (hermes_home / "config.yaml").write_text(json.dumps({"plugins": {"enabled": ["guard", "app_topic"]}}))

        from hermes_cli.plugins import discover_plugins, get_plugin_manager

        discover_plugins(force=True)
        manager = get_plugin_manager()
        assert {"guard", "app_topic"} <= set(manager._plugins), manager._plugins.keys()
        guard, app_topic = sys.modules["guard"], sys.modules["app_topic"]
        app = app_topic.STATE["app"]

        # The control shows guard's mode, and follows /mode.
        controls = app.build_controls()
        assert controls["permission_mode"] == guard.permission_mode_info(), controls["permission_mode"]
        assert controls["permission_mode"]["value"] == "ask"
        assert "permissions" in [c["id"] for c in controls["commands"]]
        manager._plugin_commands["mode"]["handler"]("auto")
        assert app.build_controls()["permission_mode"]["value"] == "auto"
        assert json.loads((hermes_home / "guard" / "mode.json").read_text()) == {"mode": "auto"}
        manager._plugin_commands["mode"]["handler"]("ask")

        # A card guard escalates, its title from guard's cache (titles.py).
        from guard import titles

        (hermes_home / "guard" / "titles.json").write_text(json.dumps({titles.key_of(LONG): TITLE}))
        from hermes_cli.plugins import _get_pre_tool_call_directive_details
        from plugins.platforms.telegram.adapter import TelegramAdapter
        from tools.approval_context import _fire_approval_hook

        adapter = TelegramAdapter.__new__(TelegramAdapter)

        def ask(command: str, n: int) -> dict:
            details = _get_pre_tool_call_directive_details("terminal", {"command": command}, session_id="s")
            assert details.action == "approve", details
            # What Hermes' gate passes for a plugin's approval (tools/approval.py, request_tool_approval).
            target = "<terminal> (plugin approval rule)"
            _fire_approval_hook("pre_approval_request", command=target, description=details.message,
                                pattern_key="plugin_rule:x", pattern_keys=["plugin_rule:x"], session_key="s",
                                surface="gateway")
            text = adapter._format_exec_approval(target, details.message, False)
            item = app.questions.from_card(chat=0, message_id=n, text_html=text, markup=card(n))
            assert item is not None and item["kind"] == "approval", item
            return item

        item = ask(LONG, 1)
        assert item["summary"] == TITLE, item
        assert TITLE in item["text"], item["text"]
        assert item["spoken"] == "Hermes wants to run a command that rebuilds the site from a clean state. Allow?", item
        # The next card, a short command with no title, does not inherit it.
        item = ask(SHORT, 2)
        assert item["summary"] is None, item
        assert item["spoken"] == "Hermes asks to use terminal. Allow?", item
        print("ok app_topic with guard")
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
