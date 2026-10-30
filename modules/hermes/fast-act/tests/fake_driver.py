"""A stand-in for `cua-driver mcp`: the browser tools browser_fast_act calls."""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import MCPServer

server = MCPServer("fake-cua-driver")
state = {"page": "inbox"}


@server.tool(structured_output=True)
def list_windows(pid: int, session: str = "") -> dict[str, Any]:
    return {"windows": [{"window_id": 7, "is_on_screen": True, "bounds": {"width": 800, "height": 600}}]}


@server.tool(structured_output=True)
def get_browser_state(
    session: str = "", pid: int = 0, window_id: int = 0, target_id: str = "", tab_id: str = "",
    snapshot_format: str = "",
) -> dict[str, Any]:
    if not snapshot_format:
        return {"target_id": "t1", "tabs": [{"tab_id": "b", "active": True}]}
    return {
        "url": "https://www.instagram.com/direct/", "title": state["page"],
        "refs": [{"ref": "p1:1", "role": "link", "name": "Thierry Martin"}],
    }


@server.tool(structured_output=True)
def browser_click(target_id: str, tab_id: str, ref: str, session: str = "") -> dict[str, Any]:
    state["page"] = "thierry"
    return {"status": "ok"}


if __name__ == "__main__":
    server.run("stdio")
