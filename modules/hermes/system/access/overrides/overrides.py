"""Hermes' local config overlay (~/.hermes/local/overrides.json): checked by
root before `server-rebuild` applies it, so Hermes can change a few of its own
settings without a push, and nothing else.

    overrides.py check <file> <policy.json>          the normalized overlay on stdout, or errors on stderr (exit 1)
    overrides.py describe <old|-> <new|->            the change in plain words, for the owner
    overrides.py secrets <overlay> <local.env> <secrets.env>
                                                     the lines of local.env the overlay's MCP servers name and
                                                     the secrets file does not already set

Fail closed: one unknown key, one bad value, and the whole file is refused.
The policy (written by Nix) holds what the repository decides: the plugins
that are enabled, the MCP servers it defines, Hermes' home.
"""

from __future__ import annotations

import json
import re
import sys

MAX_BYTES = 64 * 1024
NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
SKILL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}$")
ENV = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
REF = re.compile(r"\$\{([A-Z][A-Z0-9_]{0,63})\}")
PROVIDER = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,63}$")
MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:/@+-]{0,127}$")
EFFORTS = ("none", "minimal", "low", "medium", "high", "xhigh")
# Hermes' auxiliary tasks a model may be chosen for (hermes_cli/config_defaults.py, "auxiliary").
AUX_TASKS = ("vision", "compression", "approval", "review", "title_generation", "memory_query_rewrite",
             "voice_chat", "goal_judge", "curator", "monitor", "background_review", "compact", "web_extract",
             "session_search", "skills_hub", "mcp")
# Plugins whose settings decide who may act or what is reviewed: never local.
LOCKED_PLUGINS = ("guard", "owner_approval", "app_topic")
# Variables that redirect or arm Hermes itself: never taken from Hermes' own file.
LOCKED_ENV = re.compile(r"^(TELEGRAM_|HERMES_|WEBHOOK_|OPENJEV_|DYLD_|LD_|PYTHON|NODE_|SSL_|REQUESTS_|CURL_|"
                        r"PATH$|HOME$|SHELL$|USER$|TMPDIR$|.*_PROXY$|.*_BASE_URL$)", re.I)
HEADER = re.compile(r"^(?:(?:Bearer|Basic|Token|Bot) )?\$\{[A-Z][A-Z0-9_]{0,63}\}$")
TOP = ("mcp_servers", "skills", "plugins", "model", "fallbacks", "reasoning_effort", "auxiliary")


class Refused(Exception):
    pass


def _keys(where: str, value, allowed) -> dict:
    if not isinstance(value, dict):
        raise Refused(f"{where}: an object is expected")
    unknown = sorted(set(value) - set(allowed))
    if unknown:
        raise Refused(f"{where}: {', '.join(unknown)} cannot be set locally (allowed: {', '.join(allowed)})")
    return value


def _str(where: str, value, pattern: re.Pattern) -> str:
    if not isinstance(value, str) or not pattern.match(value):
        raise Refused(f"{where}: {json.dumps(value)} is not a valid value")
    return value


def _list(where: str, value, pattern: re.Pattern, limit: int = 32) -> list:
    if not isinstance(value, list) or len(value) > limit:
        raise Refused(f"{where}: a list of at most {limit} items is expected")
    return [_str(f"{where}[{n}]", v, pattern) for n, v in enumerate(value)]


def _mcp(name: str, server, policy: dict) -> dict:
    where = f"mcp_servers.{name}"
    _str(where, name, NAME)
    if name in policy.get("repo_mcp_servers", []):
        raise Refused(f"{where}: the repository defines this server; change it there")
    s = _keys(where, server, ("command", "args", "url", "env", "headers", "tools", "timeout", "enabled"))
    if ("command" in s) == ("url" in s):
        raise Refused(f"{where}: exactly one of command (stdio) or url (HTTP) is expected")
    out: dict = {}
    if "command" in s:
        out["command"] = _str(f"{where}.command", s["command"], re.compile(r"^[^\s\x00-\x1f]{1,512}$"))
        out["args"] = [_str(f"{where}.args", a, re.compile(r"^[^\x00-\x1f]{0,512}$")) for a in s.get("args", [])]
        if not isinstance(s.get("args", []), list) or len(out["args"]) > 32:
            raise Refused(f"{where}.args: a list of at most 32 strings is expected")
    else:
        url = _str(f"{where}.url", s["url"], re.compile(r"^(https://|http://(127\.0\.0\.1|localhost)[:/])[^\s]{1,500}$"))
        out["url"] = url
    # Secrets by name only: a value written here would land in the Nix store, readable by every user.
    if "env" in s:
        env = _keys(f"{where}.env", s["env"], [k for k in s["env"] if isinstance(k, str) and ENV.match(k)])
        out["env"] = {k: _str(f"{where}.env.{k}", v, re.compile(r"^\$\{[A-Z][A-Z0-9_]{0,63}\}$")) for k, v in env.items()}
    if "headers" in s:
        headers = _keys(f"{where}.headers", s["headers"],
                        [k for k in s["headers"] if isinstance(k, str) and re.match(r"^[A-Za-z][A-Za-z0-9-]{0,63}$", k)])
        out["headers"] = {k: _str(f"{where}.headers.{k}", v, HEADER) for k, v in headers.items()}
    if "tools" in s:
        tools = _keys(f"{where}.tools", s["tools"], ("include", "exclude"))
        out["tools"] = {k: _list(f"{where}.tools.{k}", v, re.compile(r"^[A-Za-z0-9_.-]{1,80}$"), 128) for k, v in tools.items()}
    if "timeout" in s:
        if not isinstance(s["timeout"], int) or isinstance(s["timeout"], bool) or not 1 <= s["timeout"] <= 600:
            raise Refused(f"{where}.timeout: seconds between 1 and 600 are expected")
        out["timeout"] = s["timeout"]
    if "enabled" in s:
        if not isinstance(s["enabled"], bool):
            raise Refused(f"{where}.enabled: true or false is expected")
        out["enabled"] = s["enabled"]
    return out


def _plain(where: str, value, depth: int = 0):
    """A plugin setting: JSON data, small."""
    if depth > 4:
        raise Refused(f"{where}: nested too deep")
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        if len(value) > 2000:
            raise Refused(f"{where}: too long")
        return value
    if isinstance(value, list):
        return [_plain(f"{where}[{n}]", v, depth + 1) for n, v in enumerate(value[:64])]
    if isinstance(value, dict):
        return {_str(where, k, re.compile(r"^[A-Za-z0-9_.-]{1,64}$")): _plain(f"{where}.{k}", v, depth + 1)
                for k, v in value.items()}
    raise Refused(f"{where}: not JSON data")


def _model(where: str, value) -> dict:
    m = _keys(where, value, ("provider", "model"))
    if set(m) != {"provider", "model"}:
        raise Refused(f"{where}: provider and model are expected")
    return {"provider": _str(f"{where}.provider", m["provider"], PROVIDER),
            "model": _str(f"{where}.model", m["model"], MODEL)}


def check(data, policy: dict) -> dict:
    o = _keys("overrides.json", data, TOP)
    out: dict = {}
    if "mcp_servers" in o:
        servers = _keys("mcp_servers", o["mcp_servers"], list(o["mcp_servers"]) if isinstance(o["mcp_servers"], dict) else [])
        if len(servers) > 16:
            raise Refused("mcp_servers: at most 16")
        out["mcp_servers"] = {n: _mcp(n, s, policy) for n, s in servers.items()}
    if "skills" in o:
        s = _keys("skills", o["skills"], ("disable", "enable", "external_dirs"))
        skills: dict = {k: _list(f"skills.{k}", s[k], SKILL, 64) for k in ("disable", "enable") if k in s}
        if "external_dirs" in s:
            home = policy["hermes_home"].rstrip("/") + "/"
            dirs = _list("skills.external_dirs", s["external_dirs"], re.compile(r"^/[^\x00-\x1f]{1,300}$"), 8)
            for d in dirs:
                if not d.startswith(home) or "/../" in d + "/":
                    raise Refused(f"skills.external_dirs: {d} is not inside {home}")
            skills["external_dirs"] = dirs
        out["skills"] = skills
    if "plugins" in o:
        p = _keys("plugins", o["plugins"], ("entries",))
        entries = p.get("entries", {})
        if not isinstance(entries, dict):
            raise Refused("plugins.entries: an object is expected")
        out_entries = {}
        for name, entry in entries.items():
            if name in LOCKED_PLUGINS:
                raise Refused(f"plugins.entries.{name}: this plugin's settings are the repository's only")
            if name not in policy.get("enabled_plugins", []):
                raise Refused(f"plugins.entries.{name}: not an enabled plugin (plugins.enabled is the repository's)")
            e = _keys(f"plugins.entries.{name}", entry, ("settings",))
            out_entries[name] = {"settings": _plain(f"plugins.entries.{name}.settings", e.get("settings", {}))}
        out["plugins"] = {"entries": out_entries}
    if "model" in o:
        out["model"] = _model("model", o["model"])
    if "fallbacks" in o:
        if not isinstance(o["fallbacks"], list) or len(o["fallbacks"]) > 8:
            raise Refused("fallbacks: a list of at most 8 is expected")
        out["fallbacks"] = [_model(f"fallbacks[{n}]", f) for n, f in enumerate(o["fallbacks"])]
    if "reasoning_effort" in o:
        if o["reasoning_effort"] not in EFFORTS:
            raise Refused(f"reasoning_effort: one of {', '.join(EFFORTS)}")
        out["reasoning_effort"] = o["reasoning_effort"]
    if "auxiliary" in o:
        aux = _keys("auxiliary", o["auxiliary"], AUX_TASKS)
        out["auxiliary"] = {}
        for task, t in aux.items():
            t = _keys(f"auxiliary.{task}", t, ("provider", "model", "reasoning_effort", "timeout"))
            a: dict = {}
            if "provider" in t:
                a["provider"] = _str(f"auxiliary.{task}.provider", t["provider"], PROVIDER)
            if "model" in t:
                a["model"] = _str(f"auxiliary.{task}.model", t["model"], MODEL)
            if "reasoning_effort" in t:
                if t["reasoning_effort"] not in EFFORTS:
                    raise Refused(f"auxiliary.{task}.reasoning_effort: one of {', '.join(EFFORTS)}")
                a["reasoning_effort"] = t["reasoning_effort"]
            if "timeout" in t:
                if not isinstance(t["timeout"], int) or isinstance(t["timeout"], bool) or not 1 <= t["timeout"] <= 900:
                    raise Refused(f"auxiliary.{task}.timeout: seconds between 1 and 900")
                a["timeout"] = t["timeout"]
            out["auxiliary"][task] = a
    return out


def load(path: str, policy: dict) -> dict:
    with open(path, "rb") as f:
        raw = f.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise Refused(f"overrides.json: larger than {MAX_BYTES} bytes")
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise Refused(f"overrides.json: not valid JSON ({error})")
    return check(data, policy)


def referenced_env(overlay: dict) -> set:
    names = set()
    for server in (overlay.get("mcp_servers") or {}).values():
        for value in list((server.get("env") or {}).values()) + list((server.get("headers") or {}).values()):
            names.update(REF.findall(value))
    return names


def _dotenv(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def secrets(overlay: dict, local_env: str, system_env: str) -> str:
    """Only what the overlay asks for, never what the system file sets or a variable that arms Hermes."""
    wanted = {n for n in referenced_env(overlay) if not LOCKED_ENV.match(n)} - set(_dotenv(system_env))
    values = _dotenv(local_env)
    return "".join(f"{n}={values[n]}\n" for n in sorted(wanted) if n in values and "\n" not in values[n])


def describe(old: dict, new: dict) -> str:
    """The change in plain words: "Local config: + MCP server notion; model fallback x removed"."""
    parts = []
    o, n = old.get("mcp_servers") or {}, new.get("mcp_servers") or {}
    parts += [f"+ MCP server {k}" for k in sorted(set(n) - set(o))]
    parts += [f"− MCP server {k}" for k in sorted(set(o) - set(n))]
    parts += [f"~ MCP server {k} changed" for k in sorted(set(o) & set(n)) if o[k] != n[k]]

    def model(m):
        return f"{m['provider']}/{m['model']}" if m else "the repository's"

    if old.get("model") != new.get("model"):
        parts.append(f"main model: {model(old.get('model'))} → {model(new.get('model'))}")
    of, nf = [model(m) for m in old.get("fallbacks") or []], [model(m) for m in new.get("fallbacks") or []]
    parts += [f"+ model fallback {m}" for m in nf if m not in of]
    parts += [f"− model fallback {m}" for m in of if m not in nf]
    if [m for m in of if m in nf] != [m for m in nf if m in of]:
        parts.append("model fallbacks reordered")
    if old.get("reasoning_effort") != new.get("reasoning_effort"):
        parts.append(f"reasoning: {old.get('reasoning_effort') or 'the repository’s'} → "
                     f"{new.get('reasoning_effort') or 'the repository’s'}")
    oa, na = old.get("auxiliary") or {}, new.get("auxiliary") or {}
    parts += [f"~ model for {k} changed" for k in sorted(set(oa) | set(na)) if oa.get(k) != na.get(k)]
    os_, ns = old.get("skills") or {}, new.get("skills") or {}
    for key, label in (("disable", "skill off"), ("enable", "skill back on"), ("external_dirs", "skills folder")):
        a, b = os_.get(key) or [], ns.get(key) or []
        parts += [f"+ {label} {x}" for x in b if x not in a] + [f"− {label} {x}" for x in a if x not in b]
    op, np_ = (old.get("plugins") or {}).get("entries") or {}, (new.get("plugins") or {}).get("entries") or {}
    parts += [f"~ {k} plugin settings changed" for k in sorted(set(op) | set(np_)) if op.get(k) != np_.get(k)]
    return "Local config: " + ("; ".join(parts) if parts else "no change")


def _read(path: str) -> dict:
    if path == "-":
        return {}
    with open(path) as f:
        return json.load(f)


def main(argv: list) -> int:
    try:
        if argv[:1] == ["check"] and len(argv) == 3:
            with open(argv[2]) as f:
                policy = json.load(f)
            print(json.dumps(load(argv[1], policy), indent=2, sort_keys=True))
        elif argv[:1] == ["describe"] and len(argv) == 3:
            print(describe(_read(argv[1]), _read(argv[2])))
        elif argv[:1] == ["secrets"] and len(argv) == 4:
            texts = []
            for path in argv[2:]:
                try:
                    with open(path) as f:
                        texts.append(f.read())
                except FileNotFoundError:
                    texts.append("")
            sys.stdout.write(secrets(_read(argv[1]), *texts))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
