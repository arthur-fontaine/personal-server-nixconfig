#!/usr/bin/env bash
# End to end: the real Hermes, the unii plugin, a scripted model (stub_llm.py).
# Two separate `hermes chat` processes share nothing but the memory volume, so
# the second can only answer from the view and zoom.
#
#   run.sh <hermes> <python3> <plugin dir> [work dir]
#
# Not a sandboxed check: `hermes chat` starts a local gateway the macOS build
# sandbox does not allow. Run it with `nix run .#hermes-turns`.
set -euo pipefail
hermes="$1" python="$2" plugin="$3" work="${4:-$(mktemp -d)}"
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$work/home" "$work/hermes/plugins" "$work/hermes/unii"
export HOME="$work/home" HERMES_HOME="$work/hermes"
cp -R "$plugin" "$HERMES_HOME/plugins/nix-managed-unii"
echo '{"presets": {"aside": {"memoryRead": true, "ttl": "session"}}, "default_preset": "aside", "summary_wait_seconds": 30}' \
  > "$HERMES_HOME/unii/config.json"

port="$("$python" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
log="$work/requests.jsonl"
: > "$log"
cat > "$HERMES_HOME/config.yaml" <<EOF
{
  "model": {"provider": "stub", "default": "stub-model"},
  "providers": {"stub": {"api": "http://127.0.0.1:$port/v1", "default_model": "stub-model",
                         "transport": "chat_completions", "discover_models": false,
                         "context_length": 128000}},
  "context": {"engine": "unii"},
  "plugins": {"enabled": ["unii"]},
  "memory": {"memory_enabled": false, "user_profile_enabled": false, "nudge_interval": 0},
  "approvals": {"mode": "off"},
  "updates": {"check": false},
  "terminal": {"cwd": "$work/home"},
  "_config_version": 52
}
EOF

"$python" -I "$here/stub_llm.py" "$port" "$log" &
stub=$!
trap 'kill $stub 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  "$python" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/v1/models')" 2>/dev/null && break
  sleep 0.2
done

ask() {
  "$hermes" chat --oneshot -q "$1" </dev/null >"$2" 2>"$work/stderr.log" || {
    echo "hermes failed on: $1 (model requests: $(wc -l < "$log"))" >&2
    cat "$2" "$work/stderr.log" >&2
    return 1
  }
}

ask "Remember this: the number is 7." "$work/first.txt"
ask "What number did I give you?" "$work/second.txt"

"$python" -I "$here/check.py" "$work"
echo "work dir: $work"
