"""The local overlay's checker, and server-rebuild with stubs (git,
darwin-rebuild, curl, sudo): no overlay, a valid one, an invalid one (refused,
the previous one applied), the secrets copied, a rollback, --no-overrides."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import overrides as O  # noqa: E402

POLICY = {"enabled_plugins": ["unii", "guard", "owner_approval", "cache_warm"], "repo_mcp_servers": ["fsearch"],
          "hermes_home": "/Users/hermes/.hermes"}
GOOD = {
    "mcp_servers": {"notion": {"url": "https://mcp.notion.com/mcp", "headers": {"Authorization": "Bearer ${NOTION_KEY}"},
                               "tools": {"include": ["search"]}},
                    "local": {"command": "/Users/hermes/.local/bin/srv", "args": ["--stdio"], "env": {"TOKEN": "${SRV_TOKEN}"}}},
    "skills": {"disable": ["arxiv"], "enable": ["notion"], "external_dirs": ["/Users/hermes/.hermes/local/skills"]},
    "plugins": {"entries": {"cache_warm": {"settings": {"interval": 240}}}},
    "model": {"provider": "openai-codex", "model": "gpt-5.5"},
    "fallbacks": [{"provider": "opencode-go", "model": "deepseek-v4.1-flash"}],
    "reasoning_effort": "high",
    "auxiliary": {"compression": {"provider": "opencode-go", "model": "x", "timeout": 60}},
}


def refused(data, why: str) -> None:
    try:
        O.check(data, POLICY)
    except O.Refused as error:
        assert why in str(error), (why, str(error))
        return
    raise AssertionError(f"accepted: {data}")


def test_checker() -> None:
    assert O.check(GOOD, POLICY)["mcp_servers"]["local"]["args"] == ["--stdio"]
    assert O.check({}, POLICY) == {}
    # Each forbidden area.
    refused({"permissions": {"defaultMode": "bypass"}}, "permissions cannot be set locally")
    refused({"guard": {}}, "guard cannot be set locally")
    refused({"trusted_platforms": ["webhook"]}, "cannot be set locally")
    refused({"plugins": {"enabled": ["evil"]}}, "enabled cannot be set locally")
    refused({"plugins": {"entries": {"guard": {"settings": {}}}}}, "repository's only")
    refused({"plugins": {"entries": {"owner_approval": {"allow_gateway_injection": True}}}}, "repository's only")
    refused({"plugins": {"entries": {"app_topic": {"settings": {}}}}}, "repository's only")
    refused({"plugins": {"entries": {"nope": {"settings": {}}}}}, "not an enabled plugin")
    refused({"plugins": {"entries": {"cache_warm": {"allow_tool_override": True}}}}, "cannot be set locally")
    refused({"approvals": {"mode": "off"}}, "cannot be set locally")
    refused({"terminal": {"cwd": "/"}}, "cannot be set locally")
    refused({"integrations": {"whatsapp": True}}, "cannot be set locally")
    refused({"mcp_servers": {"fsearch": {"command": "/bin/sh"}}}, "the repository defines this server")
    refused({"mcp_servers": {"x": {"url": "https://a", "headers": {"Authorization": "Bearer sk-live-123"}}}}, "not a valid value")
    refused({"mcp_servers": {"x": {"command": "a", "env": {"K": "secret"}}}}, "not a valid value")
    refused({"mcp_servers": {"x": {"url": "http://evil.example/mcp"}}}, "not a valid value")
    refused({"mcp_servers": {"x": {"command": "a", "url": "https://a"}}}, "exactly one of")
    refused({"mcp_servers": {"x": {"command": "a", "cwd": "/"}}}, "cwd cannot be set locally")
    refused({"skills": {"external_dirs": ["/etc"]}}, "is not inside")
    refused({"skills": {"external_dirs": ["/Users/hermes/.hermes/../x"]}}, "is not inside")
    refused({"model": {"provider": "x"}}, "provider and model are expected")
    refused({"reasoning_effort": "max!"}, "one of")
    refused({"auxiliary": {"approval_bypass": {}}}, "cannot be set locally")
    refused([], "an object is expected")


def test_load_and_describe(tmp: Path) -> None:
    bad = tmp / "bad.json"
    bad.write_text("{not json")
    try:
        O.load(str(bad), POLICY)
        raise AssertionError("invalid JSON accepted")
    except O.Refused as error:
        assert "not valid JSON" in str(error)
    old = {"fallbacks": [{"provider": "openai-codex", "model": "gpt-5.5"}]}
    new = {"mcp_servers": {"notion": {"url": "https://x"}}}
    assert O.describe(old, new) == "Local config: + MCP server notion; − model fallback openai-codex/gpt-5.5"
    assert O.describe(new, new) == "Local config: no change"
    # Only the keys the overlay names, never one the system file sets or that arms Hermes.
    overlay = {"mcp_servers": {"a": {"url": "https://a", "headers": {"Authorization": "Bearer ${NOTION_KEY}"}},
                               "b": {"command": "x", "env": {"T": "${TELEGRAM_BOT_TOKEN}", "U": "${RUNPOD_API_KEY}",
                                                             "P": "${HTTPS_PROXY}"}}}}
    local = "NOTION_KEY=n1\nTELEGRAM_BOT_TOKEN=evil\nRUNPOD_API_KEY=mine\nHTTPS_PROXY=http://evil\nOTHER=x\n"
    assert O.secrets(overlay, local, "RUNPOD_API_KEY=system\n") == "NOTION_KEY=n1\n"


def stub(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def test_rebuild(tmp: Path) -> None:
    bash = os.environ.get("BASH_BIN", "/bin/bash")
    bin_ = tmp / "bin"
    bin_.mkdir()
    log = tmp / "log"
    stub(bin_ / "git", f'echo "git $*" >> {log}\n')
    stub(bin_ / "darwin-rebuild", f'echo "darwin-rebuild $*" >> {log}\n')
    stub(bin_ / "curl", f'echo "curl $*" >> {log}\n')
    stub(bin_ / "run", '"$@"\n')  # sudo -u …, as the caller here
    stub(bin_ / "check", f'exec "{sys.executable}" -I "{HERE / "overrides.py"}" "$@"\n')
    repo, home = tmp / "repo", tmp / "home"
    (repo / "hosts").mkdir(parents=True)
    (home / "local").mkdir(parents=True)
    policy = tmp / "policy.json"
    policy.write_text(json.dumps({**POLICY, "hermes_home": str(home)}))
    secrets = tmp / "secrets.env"
    secrets.write_text("TELEGRAM_BOT_TOKEN=tok\nTELEGRAM_ALLOWED_USERS=42\n")
    env = {**os.environ, "DIR": str(repo), "HOST": "h", "HERMES_USER": os.environ.get("USER") or str(os.getuid()),
           "OVERLAY": str(home / "local/overrides.json"), "LOCAL_SECRETS": str(home / "local/secrets.env"),
           "STATE": str(tmp / "state"), "SECRETS": str(secrets), "ENV_OUT": str(tmp / "local-secrets.env"),
           "POLICY": str(policy), "CHECK": str(bin_ / "check"), "GIT": str(bin_ / "git"),
           "DARWIN_REBUILD": str(bin_ / "darwin-rebuild"), "CURL": str(bin_ / "curl"),
           "AS_ADMIN": str(bin_ / "run"), "AS_HERMES": str(bin_ / "run")}
    env["HERMES_USER"] = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
    applied = repo / "hosts/hermes-overrides.json"

    def run(*args) -> subprocess.CompletedProcess:
        log.write_text("")
        r = subprocess.run([bash, str(HERE / "server-rebuild.sh"), *args], env=env, capture_output=True, text=True)
        assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
        assert f"darwin-rebuild switch --flake path:{repo}#h" in log.read_text(), log.read_text()
        assert log.read_text().startswith(f"git -C {repo} pull --ff-only")
        return r

    def history() -> list:
        return sorted(p.name for p in (tmp / "state/history").glob("*.json"))

    # No overlay: nothing placed, nobody told.
    run()
    assert not applied.exists() and "curl" not in log.read_text() and history() == []
    # A valid one: placed, normalized, kept, the owner told, its key copied.
    (home / "local/overrides.json").write_text(json.dumps({"mcp_servers": GOOD["mcp_servers"]}))
    (home / "local/secrets.env").write_text("NOTION_KEY=n1\nTELEGRAM_BOT_TOKEN=evil\n")
    r = run()
    assert json.loads(applied.read_text())["mcp_servers"]["notion"]["url"] == "https://mcp.notion.com/mcp"
    assert "Local config: + MCP server local; + MCP server notion" in r.stdout
    assert "chat_id=42" in log.read_text() and "MCP server notion" in log.read_text()
    assert (tmp / "local-secrets.env").read_text() == "NOTION_KEY=n1\n"
    assert len(history()) == 1 and len(list((home / "local/history").glob("*.json"))) == 1
    first = history()[0]
    # The same again: no new version, no message.
    run()
    assert "curl" not in log.read_text() and len(history()) == 1
    # Invalid: refused whole, the previous overlay applied unchanged, the owner told.
    before = applied.read_text()
    (home / "local/overrides.json").write_text(json.dumps({"permissions": {"defaultMode": "bypass"}}))
    r = run()
    assert applied.read_text() == before and "refused" in r.stderr and "Local config refused" in log.read_text()
    (home / "local/overrides.json").write_text("{oops")
    run()
    assert applied.read_text() == before
    # Another valid version, then a rollback to the first.
    import time
    time.sleep(1.1)  # the history is keyed by the second
    (home / "local/overrides.json").write_text(json.dumps({"fallbacks": GOOD["fallbacks"]}))
    run()
    assert "fallbacks" in json.loads(applied.read_text()) and len(history()) == 2
    time.sleep(1.1)
    r = run("--overrides-rollback", first)
    assert "mcp_servers" in json.loads(applied.read_text()) and "rolled back" in r.stdout
    assert "mcp_servers" in json.loads((home / "local/overrides.json").read_text())
    # Without it, this once.
    time.sleep(1.1)
    r = run("--no-overrides")
    assert not applied.exists() and (tmp / "local-secrets.env").read_text() == ""
    assert "− MCP server notion" in r.stdout
    # An unknown version: refused before anything is applied.
    r = subprocess.run([bash, str(HERE / "server-rebuild.sh"), "--overrides-rollback", "nope"], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 1 and "no overlay version" in r.stderr and "nope" in r.stderr


def main() -> None:
    tmp = Path(tempfile.mkdtemp(prefix="overrides-test-"))
    try:
        test_checker()
        print("ok checker")
        test_load_and_describe(tmp)
        print("ok load, describe, secrets")
        test_rebuild(tmp)
        print("ok server-rebuild")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
