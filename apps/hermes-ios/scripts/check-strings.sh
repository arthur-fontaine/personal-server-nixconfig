#!/bin/sh
# Every string the app's last build uses has a French translation (design-rules 3): syncs a copy of
# the catalogue with the build's .stringsdata, then lists keys with no "fr", or "fr" not translated.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
dd="${1:-$HOME/Library/Caches/hermes-ios/DerivedData}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$here/HermesApp/Localizable.xcstrings" "$tmp/"
find "$dd/Build/Intermediates.noindex" -path '*HermesApp.build*' -name '*.stringsdata' > "$tmp/list"
[ -s "$tmp/list" ] || { echo "check-strings: no .stringsdata under $dd (build first)"; exit 2; }
xargs xcrun xcstringstool sync "$tmp/Localizable.xcstrings" --stringsdata < "$tmp/list" >/dev/null
python3 -I - "$tmp/Localizable.xcstrings" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["strings"]
def done(loc):
    if not loc: return False
    if "stringUnit" in loc: return loc["stringUnit"].get("state") == "translated"
    v = loc.get("variations", {})
    return all(done(x) for kind in v.values() for x in kind.values()) and bool(v)
bad = [k for k, v in s.items() if k.strip() and v.get("shouldTranslate", True)
       and v.get("extractionState") != "stale" and not done(v.get("localizations", {}).get("fr"))]
for k in bad: print("untranslated (fr):", repr(k))
print(f"check-strings: {len(s)} keys, {len(bad)} untranslated")
sys.exit(1 if bad else 0)
PY
