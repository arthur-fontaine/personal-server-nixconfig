"""Calls that never reach the classifier (Claude Code's auto mode, SPEC §1;
Pi extension auto-mode, fastpath.ts): the safe allowlist of tools that only
look, tools that ask the owner themselves, and what Claude Code's acceptEdits
mode or its Bash read-only check (readonly.py) would allow, inside Hermes'
working directory.
"""

from __future__ import annotations

import os
import re
from typing import Mapping, Optional

from .readonly import read_only_refusal, realish

# Hermes' counterparts of Claude Code's safe allowlist (Read, Grep, Glob,
# ToolSearch, Todo…): they only look, or act on Hermes' own state. Opening a
# page (web_extract) is not here: its URL can carry data out.
ALLOWLIST = frozenset({
    "read_file", "search_files", "session_search", "skill_view", "skills_list",
    "web_search", "x_search", "vision_analyze", "video_analyze",
    "todo", "todo_list", "read_terminal", "read_window_below", "show_tip",
    "memory", "react_to_message", "tool_search", "tool_describe",
    # unii's own tools: they open its memory's view.
    "zoom", "date",
    # The sandbox's grants, the app's devices and installed apps, listed.
    "sandbox_grants", "app_devices", "sideload_devices", "sideload_apps",
})
# Tools that put their own question to the owner, as AskUserQuestion does.
INTERACTIVE = frozenset({"clarify", "propose"})
# computer_use's actions that only look (tools/computer_use/tool.py, _ACTIONS).
LOOKING = frozenset({"capture", "wait", "list_apps", "list_windows"})
# fsearch only finds files; imcp-read is iMCP's read-only tools (agent/events.nix).
READ_ONLY_SERVERS = ("mcp__fsearch__", "mcp__imcp_read__")
# cua-driver's tools that only look (`cua-driver list-tools`). Not
# clipboard_read: the clipboard may hold what the owner copied.
CUA_LOOKING = frozenset("mcp__cua__" + t for t in (
    "get_window_state", "get_desktop_state", "get_accessibility_tree", "zoom", "list_windows", "list_apps",
    "get_screen_size", "get_cursor_position", "get_config", "get_guide", "check_permissions", "health_report",
    "get_session", "list_sessions", "parse_visual_regions", "verify_state",
))

PROTECTED_DIRS = {".git", ".vscode", ".idea", ".claude", ".pi", ".hermes"}
PROTECTED_FILES = set((
    ".gitconfig .gitmodules .bashrc .bash_profile .zshrc .zprofile .profile .zshenv .zlogin .zlogout .bash_login "
    ".bash_aliases .bash_logout .envrc .ripgreprc .mcp.json .claude.json .npmrc .yarnrc .yarnrc.yml .pnp.cjs "
    ".pnp.loader.mjs .pnpmfile.cjs bunfig.toml .bunfig.toml .bazelrc .bazelversion .bazeliskrc "
    ".pre-commit-config.yaml lefthook.yml .lefthook.yml lefthook.yaml .lefthook.yaml gradle-wrapper.properties "
    "maven-wrapper.properties .devcontainer.json pyrightconfig.json").split())


def looks_only(tool: str, args: Mapping) -> bool:
    if tool == "computer_use":
        return args.get("action") in LOOKING
    return tool in ALLOWLIST or tool in CUA_LOOKING or tool.startswith(READ_ONLY_SERVERS)


def _resolve(cwd: str, target: str) -> str:
    expanded = os.path.expanduser(target) if target.startswith("~") else target
    return realish(os.path.normpath(os.path.join(cwd, expanded)))


def editable(cwd: str, target: str) -> bool:
    """A path acceptEdits may write: inside the working directory and not a protected file."""
    root = realish(os.path.abspath(cwd))
    rel = os.path.relpath(_resolve(cwd, target), root)
    if rel == "." or rel.startswith("..") or os.path.isabs(rel):
        return False
    parts = rel.split(os.sep)
    if any(p.lower() in PROTECTED_DIRS for p in parts):
        return False
    return parts[-1].lower() not in PROTECTED_FILES


# Claude Code's acceptEdits Bash commands, each target inside the working directory.
FILE_COMMANDS = {"mkdir", "touch", "rm", "rmdir", "mv", "cp", "sed"}
# A plain s/// script: no w, e or r commands that could reach other files or run commands.
PLAIN_SED = re.compile(r"^s([^\\\n\w\s])(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1[gIip0-9]*$")


def _file_command_allowed(cmd, cwd: str) -> bool:
    if not cmd.argv or cmd.argv[0] not in FILE_COMMANDS or cmd.redirects or cmd.env:
        return False
    name, args = cmd.argv[0], cmd.argv[1:]
    operands = [a for a in args if not a.startswith("-")]
    # A glob's matches are unknown until it runs; the classifier judges those.
    if any(w.glob for w in cmd.words) or any(re.search(r"[*?[]", a) for a in operands):
        return False
    if name == "sed":
        if any(a.startswith("-") and not re.fullmatch(r"-(?:[nEri]+|i\.\w+|-in-place|-regexp-extended|-quiet)", a) for a in args):
            return False
        if not operands or not PLAIN_SED.match(operands[0]):
            return False
        operands = operands[1:]
    if not operands:
        return name not in ("rm", "rmdir", "sed")
    return all(editable(cwd, p) for p in operands)


def bash_fast_path(command: str, cwd: str) -> Optional[str]:
    from .readonly import parse

    if read_only_refusal(command, cwd) is None:
        return "readOnly"
    script = parse(command)
    if script and script.commands and all(_file_command_allowed(c, cwd) for c in script.commands):
        return "acceptEdits"
    return None


def fast_path(tool: str, args: Mapping, cwd: str) -> Optional[str]:
    """Why the call runs without the classifier ("allowlist", "interactive",
    "acceptEdits", "readOnly"), or None."""
    args = args or {}
    if looks_only(tool, args):
        return "allowlist"
    if tool in INTERACTIVE:
        return "interactive"
    if tool in ("write_file", "patch") and isinstance(args.get("path"), str):
        return "acceptEdits" if editable(cwd, args["path"]) else None
    if tool == "terminal" and isinstance(args.get("command"), str) and not args.get("background"):
        where = args.get("workdir") if isinstance(args.get("workdir"), str) and args.get("workdir") else cwd
        if where != cwd and not editable(cwd, os.path.join(where, "x")):
            return None
        return bash_fast_path(args["command"], where if where == cwd else cwd)
    return None
