"""browser_fast_act: Hermes' Chrome driven by a decision model through Cua.

The loop of Cua's jev-use browser runner (libs/cua-driver/examples/jev-use at
2d974f1843c7343a70affba9d21e7362979edec3, python/run.py): Cua Driver snapshots
the page, candidates.build asks the operation and its targets, the decision
model answers them in one request, Cua Driver performs the operation on its
target, and again, until the model says the goal is reached or abstains. The model writes nothing: the text to type is Hermes'.
Hermes stays the judge of the outcome: the tool reports what it did.

Environment: CUA_DRIVER_BIN, FAST_ACT_CHROME_PROFILE (the --user-data-dir of
Hermes' always-open Chrome) and decision.py's OPENJEV_* settings.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import time
from typing import Any

from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client
from mcp.server.mcpserver import MCPServer

from fast_act import candidates as cands
from fast_act import decision

SESSION = "hermes-fast-act"


class DriverError(RuntimeError):
    pass


class Driver:
    """Cua Driver's MCP tools, as jev-use's run.py Driver calls them."""

    def __init__(self, session: ClientSession) -> None:
        self.session = session

    async def call(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        result = await self.session.call_tool(name, {**arguments, "session": SESSION})
        data = getattr(result, "structured_content", None)
        if getattr(result, "is_error", False) or not isinstance(data, dict):
            text = " ".join(getattr(part, "text", "") for part in getattr(result, "content", None) or [])
            raise DriverError(f"{name} failed: {text[:300] or 'no structured result'}")
        if data.get("status") == "refused" or data.get("refusal"):
            raise DriverError(f"{name} refused: {data.get('refusal', data)}")
        return data


def chrome_pid(profile: str) -> int:
    """Hermes' Chrome: the browser process on that profile, not its helpers."""
    out = subprocess.run(["/bin/ps", "-axo", "pid=,args="], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        pid, _, args = line.strip().partition(" ")
        if f"--user-data-dir={profile}" in args and "--type=" not in args:
            return int(pid)
    raise DriverError("Hermes' Chrome is not running")


async def bind(driver: Driver, pid: int) -> tuple[str, str]:
    """Its largest on-screen window's target and active tab (jev-use's wait_for_window, select_tab_id)."""
    windows = [w for w in (await driver.call("list_windows", {"pid": pid})).get("windows", []) if w.get("is_on_screen")]
    if not windows:
        raise DriverError("Hermes' Chrome has no window on screen")
    window = max(windows, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"])
    state = await driver.call("get_browser_state", {"pid": pid, "window_id": window["window_id"]})
    tabs = state.get("tabs") or []
    if not tabs:
        raise DriverError("Hermes' Chrome has no tab")
    tab = next((t for t in tabs if t.get("active")), tabs[0])
    return str(state["target_id"]), str(tab["tab_id"])


def decision_state(goal: str, snapshot: dict[str, Any], history: list[dict[str, str]]) -> dict[str, Any]:
    outline = snapshot.get("outline")
    return {
        "goal": goal,
        "observation": {
            "page": {"url": snapshot.get("url"), "title": snapshot.get("title")},
            "outline": outline[:6000] if isinstance(outline, str) else outline,
        },
        "history": history[-8:],
    }


async def run(
    goal: str,
    *,
    texts: list[str],
    url: str | None,
    allow_risky: bool,
    max_steps: int,
    driver: Driver,
    pid: int,
    config: decision.Config,
) -> str:
    target_id, tab_id = await bind(driver, pid)
    if url:
        await driver.call("browser_navigate", {"target_id": target_id, "tab_id": tab_id, "url": url})
    history: list[dict[str, str]] = []
    report: list[str] = []
    for step in range(1, max_steps + 1):
        started = time.perf_counter()
        snapshot = await driver.call(
            "get_browser_state", {"target_id": target_id, "tab_id": tab_id, "snapshot_format": "semantic_v2"}
        )
        snapshot.setdefault("target_id", target_id)
        snapshot.setdefault("tab_id", tab_id)
        questions = cands.build(snapshot, goal=goal, texts=texts, allow_risky=allow_risky)
        try:
            answers = await asyncio.to_thread(
                decision.ask, config, state=decision_state(goal, snapshot, history), questions=questions.criteria()
            )
        except decision.DecisionError as error:
            report.append(f"{step}. stopped: {error}")
            break
        operation = answers["operation"]
        ms = round((time.perf_counter() - started) * 1000)
        if operation.selected_id == cands.REOBSERVE:
            report.append(f"{step}. looked again ({ms} ms)")
            history.append({"step": str(step), "action": "reobserve"})
            await asyncio.sleep(0.5)
            continue
        if operation.selected_id in {cands.DONE, cands.ABSTAIN}:
            report.append(f"{step}. {cands.OPERATIONS[operation.selected_id]} (p={operation.confidence:.2f}, {ms} ms)")
            break
        if operation.selected_id == cands.CLICK:
            target = answers["click_target"]
            element = questions.clickable[target.selected_id]
            tool, arguments = questions.click(target.selected_id)
            description = f"Click {element.description}"
        else:
            target = answers["type_target"]
            element = questions.typable[target.selected_id]
            if not texts:
                # jev-ultrafast's small LLM would write it: here that is Hermes.
                report.append(f"{step}. stopped: typing into {element.description} needs a text; call again with it in texts")
                break
            text = texts[int(answers["text"].selected_id[1:])] if len(texts) > 1 else texts[0]
            tool, arguments = questions.type(target.selected_id, text)
            description = f'Type "{cands.preview(text)}" into {element.description}'
        line = f"{step}. {description} (p={min(operation.confidence, target.confidence):.2f}, {ms} ms)"
        try:
            await driver.call(tool, arguments)
        except DriverError as error:
            report.append(f"{line}: failed, {error}")
            history.append({"step": str(step), "action": description, "result": "failed"})
            continue
        report.append(line)
        history.append({"step": str(step), "action": description})
    else:
        report.append(f"stopped after {max_steps} steps")
    return "\n".join(report)


server = MCPServer(
    "fast-act",
    instructions=(
        "browser_fast_act clicks and types through a web page in Hermes' Chrome, choosing each "
        "action with a fast decision model instead of screenshots. Give it one concrete goal and "
        "every text to type, written in full, then check the page yourself."
    ),
)


@server.tool()
async def browser_fast_act(
    goal: str,
    texts: list[str] | None = None,
    url: str | None = None,
    allow_risky: bool = False,
    max_steps: int = 8,
) -> str:
    """Reach a goal on a web page in Hermes' Chrome, fast.

    goal: one concrete outcome on the page ("send Thierry the message").
    texts: every text to type on the way, written by you, in full ("Thierry",
        then the message): the model only picks which goes into which field.
    url: a page to open first; otherwise the current tab.
    allow_risky: offer send, delete, publish, pay... (only when the user asked for it).
    max_steps: at most this many actions.
    Returns each step taken; check the result before telling the user.
    """
    config = decision.Config.from_env()
    pid = chrome_pid(os.environ["FAST_ACT_CHROME_PROFILE"])
    params = StdioServerParameters(command=os.environ.get("CUA_DRIVER_BIN", "cua-driver"), args=["mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            return await run(
                goal,
                texts=list(texts or []),
                url=url,
                allow_risky=allow_risky,
                max_steps=max(1, min(max_steps, 20)),
                driver=Driver(session),
                pid=pid,
                config=config,
            )


def main() -> None:
    server.run("stdio")


if __name__ == "__main__":
    main()
