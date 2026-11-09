#!/bin/bash
# Asks auto mode's review model about one harmless command, as guard does, and
# prints what it answers: the prompt guard uses, the request's size, the
# verdict, and the model's own error when it refuses. Run on the server after
# a rebuild (it reads Hermes' secrets, so it asks for sudo):
#   scripts/guard-probe.sh            # "ls ~/workspace | head" after "list my workspace"
#   scripts/guard-probe.sh 'git push --force origin main' 'push it'
set -euo pipefail

command=${1:-'ls ~/workspace | head'}
request=${2:-'Liste les fichiers de mon dossier workspace'}
config=${GUARD_CONFIG:-/Users/hermes/.hermes/guard/config.json}

# The guard plugin and Hermes' interpreter of the running system, whatever
# their store paths: guard.nix names the plugin, Hermes' venv holds python3.
closure=$(nix-store -qR /run/current-system)
plugin=$(grep -E -- '-hermes-plugin-guard$' <<<"$closure" | head -1 || true)
venv=$(grep -E -- '-hermes-agent-env$' <<<"$closure" | head -1 || true)
if [ -z "$plugin" ] || [ -z "$venv" ] || [ ! -x "$venv/bin/python3" ]; then
  echo "guard-probe: no guard plugin or Hermes interpreter in /run/current-system" >&2
  exit 1
fi
echo "plugin: $plugin"
echo "python: $venv/bin/python3"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The store path is no module name: guard is imported through a symlink.
ln -s "$plugin" "$tmp/guard"

sudo env PROBE_DIR="$tmp" PROBE_CONFIG="$config" PROBE_COMMAND="$command" PROBE_REQUEST="$request" \
  sh -c 'set -a; . /etc/hermes/secrets.env; set +a; cd "$PROBE_DIR" && exec "$0" -I -' "$venv/bin/python3" <<'PY' 2>&1 |
import json, logging, os, pathlib, sys

sys.path.insert(0, os.environ["PROBE_DIR"])
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
import guard
from guard import systemone, transcript

cfg = json.loads(pathlib.Path(os.environ["PROBE_CONFIG"]).read_text())
if not cfg.get("model"):
    sys.exit("no review model configured (server.hermes.decision.approval is off): auto mode asks for every action")
model = systemone.Config.from_env({
    "OPENJEV_BASE_URL": cfg["url"], "OPENJEV_MODEL": cfg["model"], "OPENJEV_AUTH_SCHEME": cfg["auth_scheme"],
    "OPENJEV_API_KEY": os.environ.get(cfg.get("key_env") or "", ""),
    "OPENJEV_TIMEOUT_MS": str(cfg.get("timeout_ms", 20000))})
print("model:", model.model, "at", model.url, "| key set:", bool(model.api_key))
g = guard.Guard(model, cfg.get("trusted_platforms", ["telegram"]), "auto", rules=cfg.get("rules") or {},
                identity=cfg.get("identity", ""), cwd=cfg.get("cwd", ""), context_file=cfg.get("context_file", ""),
                max_prompt_tokens=int(cfg.get("max_prompt_tokens") or guard.DEFAULT_MAX_PROMPT_TOKENS))
lines = [transcript.line("user", transcript.indent(os.environ["PROBE_REQUEST"]))]
action = transcript.call_line("terminal", {"command": os.environ["PROBE_COMMAND"]})
r = g.request(lines, action)
print(f"prompt: {r.variant} | request ~{r.tokens} tokens (budget {g.max_prompt_tokens}) | "
      f"AGENTS.md {'cut' if r.context_cut else 'whole'}")
v = g.classify(lines, action)
p = f" | p(block) {v.block_probability:.2f}" if v.block_probability is not None else ""
print(f"verdict: {v.kind} | {v.reason}{p}")
if v.error:
    print("error:", v.error)
sys.exit(0 if v.kind in ("allow", "block") else 2)
PY
  sed -E 's/(Api-Key|Bearer) [A-Za-z0-9._-]+/\1 <key>/g'
