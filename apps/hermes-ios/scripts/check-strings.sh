#!/bin/sh
# Every string the last build uses has a French translation (design-rules 3): for the app's and the
# widget extension's catalogues, syncs a copy with the build's .stringsdata, then lists keys with
# no "fr", or "fr" not translated.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
dd="${1:-$HOME/Library/Caches/hermes-ios/DerivedData}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
status=0
for pair in "HermesApp:HermesApp" "HermesWidgets:HermesWidgets"; do
  dir="${pair%%:*}"; target="${pair##*:}"
  mkdir -p "$tmp/$dir"; cp "$here/$dir/Localizable.xcstrings" "$tmp/$dir/"
  find "$dd/Build/Intermediates.noindex" -path "*/$target.build/*" -name '*.stringsdata' > "$tmp/$dir/list"
  [ -s "$tmp/$dir/list" ] || { echo "check-strings: no .stringsdata for $target under $dd (build first)"; exit 2; }
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
