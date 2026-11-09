#!/bin/bash
# Hatches one test pet with the real image provider, as pet_generate does
# (modules/hermes/plugins/app_topic/hatch.py), into a temporary Hermes home:
# it is not installed as the app's pet. Prints the cost, time, the path taken
# (one sheet, rows redrawn), the validation, and copies the sheet, the
# atlas and its contact sheet to ~/pet-probe/. Run on the server after a
# rebuild (it reads Hermes' secrets, so it asks for sudo):
#   scripts/pet-probe.sh                         # a small round blue owl, $0.60 at most
#   scripts/pet-probe.sh 'a grumpy cactus' 0.45
set -euo pipefail

description=${1:-'a small round blue owl with big amber eyes'}
budget=${2:-0.60}
config=${PET_PROBE_CONFIG:-/Users/hermes/.hermes/config.yaml}
secrets=${PET_PROBE_SECRETS:-/etc/hermes/secrets.env}
out="$HOME/pet-probe"

# The app_topic plugin and Hermes' interpreter of the running system,
# whatever their store paths (agent/app.nix names the plugin).
closure=$(nix-store -qR /run/current-system)
plugin=$(grep -E -- '-hermes-plugin-app-topic$' <<<"$closure" | head -1 || true)
venv=$(grep -E -- '-hermes-agent-env$' <<<"$closure" | head -1 || true)
if [ -z "$plugin" ] || [ -z "$venv" ] || [ ! -x "$venv/bin/python3" ]; then
  echo "pet-probe: no app_topic plugin or Hermes interpreter in /run/current-system" >&2
  exit 1
fi
echo "plugin: $plugin"
echo "python: $venv/bin/python3"

tmp=$(mktemp -d)
trap 'sudo rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/lib" "$out"
# The store path is no module name: app_topic is imported through a symlink.
ln -s "$plugin" "$tmp/lib/app_topic"
# Hermes' image settings (provider, model), in a home of its own: no pet,
# image or config of the real one is touched.
sudo cp "$config" "$tmp/home/config.yaml"

set +e
sudo env PROBE_DIR="$tmp" PROBE_OUT="$out" PROBE_DESCRIPTION="$description" PROBE_BUDGET="$budget" PROBE_SECRETS="$secrets" \
  HERMES_HOME="$tmp/home" \
  sh -c 'set -a; . "$PROBE_SECRETS"; set +a; cd "$PROBE_DIR" && exec "$0" -I -' "$venv/bin/python3" <<'PY' 2>&1 |
import json, logging, os, shutil, sys, time
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["PROBE_DIR"], "lib"))
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
from agent.pet.generate import imagegen
from app_topic import hatch

sprite = imagegen.resolve_provider(require_references=True)
hatch.openrouter_knobs(sprite.provider)
model = getattr(sprite.provider, "_resolve_model", lambda: "?")()
print(f"provider: {sprite.name} | model: {model} | budget: ${float(os.environ['PROBE_BUDGET']):.2f}")
work = Path(os.environ["PROBE_DIR"]) / "work"
out = Path(os.environ["PROBE_OUT"])
t0 = time.monotonic()
status = 0
try:
    _, report = hatch.hatch(os.environ["PROBE_DESCRIPTION"], sprite=sprite, work=work,
                            max_cost=float(os.environ["PROBE_BUDGET"]))
    print("result: hatched")
except (hatch.ProviderRefused, hatch.HatchFailed) as error:
    report, status = error.report, 2
    print(f"result: {type(error).__name__}: {error}")
budget = report.get("budget") or {}
print(f"time: {time.monotonic() - t0:.0f}s")
print(f"cost: ${budget.get('spent', 0):.3f} (reported ${budget.get('reported', 0):.3f}, "
      f"estimated ${budget.get('estimated', 0):.3f}) of ${budget.get('limit', 0):.2f}")
for call in budget.get("calls", []):
    print(f"  call {call['what']}: ${call['cost']:.3f} ({call['how']})")
print(f"path: {report.get('path')} | rows redrawn: {report.get('repaired_rows') or 'none'} | "
      f"running-left mirrored: {report.get('mirrored_left')}")
for state, why in (report.get("row_errors") or {}).items():
    print(f"  row {state}: {why}")
validation = report.get("validation") or {}
print(f"validation: ok={validation.get('ok')} errors={validation.get('errors')} "
      f"warnings={validation.get('warnings')} filled={len(validation.get('filled_states') or [])}/9")
for name in ("sheet.png", "guide.png", "spritesheet.png", "contact-sheet.png", "report.json") + tuple(
        p.name for p in work.glob("row-*")):
    if (work / name).is_file():
        shutil.copy(work / name, out / name)
print(f"files: {out}")
sys.exit(status)
PY
  sed -E 's/(Bearer|sk-or-v1-)[A-Za-z0-9._-]+/\1<key>/g'
status=${PIPESTATUS[0]}
set -e
sudo chown -R "$(id -u):$(id -g)" "$out"
exit "$status"
