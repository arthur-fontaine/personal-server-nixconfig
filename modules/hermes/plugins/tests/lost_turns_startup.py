"""Child of test_lost_turns.py: plugins load the way `hermes gateway` loads
them, in a fresh interpreter (gateway.run and the plugin registry are process
state). Prints what came of lost_turns' load as JSON.

hermes_cli/main.py starts plugin discovery on a background thread, then the
main thread imports gateway.run, whose config bridge waits for that discovery
(gateway/run.py, _bridge_auxiliary_config_to_env, with an `auxiliary`
section). On the loaded server lost_turns' register() ran while that import
was still in progress (agent.log, 2026-11-07 17:14). Here the bridge starts
the discovery and waits until lost_turns is loading before it goes on: that
order is the one tested, not a race. There the main thread holds only
gateway.run's import lock, as on the server.
"""

from __future__ import annotations

import json
import sys
import threading
import time


def lost_turns_loading() -> bool:
    return any(name.rsplit(".", 1)[-1] == "lost_turns" for name in list(sys.modules))


held = []


def hold_the_bridge() -> None:
    import hermes_cli.plugins as plugins
    bridge = plugins.get_plugin_auxiliary_tasks

    def get_plugin_auxiliary_tasks():
        run = sys.modules.get("gateway.run")
        if not held and run is not None and getattr(run.__spec__, "_initializing", False):
            held.append(True)
            plugins.start_background_plugin_discovery()
            deadline = time.monotonic() + 60
            while not lost_turns_loading():
                if time.monotonic() > deadline:
                    raise SystemExit("lost_turns never started loading")
                time.sleep(0.01)
        return bridge()

    plugins.get_plugin_auxiliary_tasks = get_plugin_auxiliary_tasks


def main() -> None:
    hold_the_bridge()
    started = time.monotonic()
    import gateway.run  # noqa: F401
    from hermes_cli.plugins import discover_plugins, get_plugin_manager
    discover_plugins()  # joins the background discovery
    elapsed = time.monotonic() - started
    manager = get_plugin_manager()
    loaded = next((p for key, p in manager._plugins.items() if key.rsplit(":", 1)[-1] == "lost_turns"), None)
    hooks = [f"{getattr(cb, '__module__', '')}.{getattr(cb, '__name__', '')}"
             for cb in manager._hooks.get("pre_gateway_dispatch", [])]
    print(json.dumps({
        "held": bool(held), "elapsed": elapsed, "found": loaded is not None,
        "enabled": bool(loaded and loaded.enabled), "error": loaded.error if loaded else None,
        "hooks": hooks,
        "boot_thread": any(t.name == "lost_turns-boot" for t in threading.enumerate()),
    }))


if __name__ == "__main__":
    main()
