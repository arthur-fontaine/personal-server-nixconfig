#!/bin/sh
# Every string the last build uses has a French translation (design-rules 3): for the app's and the
# widget extension's catalogues, syncs a copy with the build's .stringsdata, then lists keys with
# no "fr", or "fr" not translated.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
dd="${1:-$HOME/Library/Caches/hermes-ios/DerivedData}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
status=0
# HermesUI's strings resolve in the app's catalogue (Text looks them up in the main bundle).
for pair in "HermesApp:HermesApp HermesUI" "HermesWidgets:HermesWidgets"; do
  dir="${pair%%:*}"; targets="${pair##*:}"
  mkdir -p "$tmp/$dir"; cp "$here/$dir/Localizable.xcstrings" "$tmp/$dir/"
  : > "$tmp/$dir/list"
  for target in $targets; do
    find "$dd/Build/Intermediates.noindex" -path "*/$target.build/*" -name '*.stringsdata' >> "$tmp/$dir/list"
  done
  [ -s "$tmp/$dir/list" ] || { echo "check-strings: no .stringsdata for $targets under $dd (build first)"; exit 2; }
  xargs xcrun xcstringstool sync "$tmp/$dir/Localizable.xcstrings" --stringsdata < "$tmp/$dir/list" >/dev/null
  python3 -I - "$tmp/$dir/Localizable.xcstrings" "$dir" <<'PY' || status=1
import json, sys
s = json.load(open(sys.argv[1]))["strings"]
def done(loc):
    if not loc: return False
    if "stringUnit" in loc: return loc["stringUnit"].get("state") == "translated"
    v = loc.get("variations", {})
    return bool(v) and all(done(x) for kind in v.values() for x in kind.values())
bad = [k for k, v in s.items() if k.strip() and v.get("shouldTranslate", True)
       and v.get("extractionState") != "stale" and not done(v.get("localizations", {}).get("fr"))]
for k in bad: print(f"untranslated (fr) in {sys.argv[2]}:", repr(k))
print(f"check-strings {sys.argv[2]}: {len(s)} keys, {len(bad)} untranslated")
sys.exit(1 if bad else 0)
PY
done
exit $status
