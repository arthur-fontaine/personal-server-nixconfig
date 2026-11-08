#!/bin/bash
# Screenshots of every screen, portrait and landscape, on an iPhone and an iPad simulator.
# Usage: [LANGUAGE=fr] scripts/screenshots.sh <out-dir> ["iPhone 17 Pro" "iPad Pro 13-inch (M5)"]
# LANGUAGE sets the simulator's own language (default en), not only the app's: the Live Activity
# and the system's prompts follow the device. Files are named <lang>-<device>-<orientation>-<screen>.png.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(cd "${1:?out dir}" && pwd)"; shift || true
lang="${LANGUAGE:-en}"
case "$lang" in
  fr) locale=fr_FR ;;
  *) locale=en_US ;;
esac
devices=("${@:-}")
[ -n "${devices[0]:-}" ] || devices=("iPhone 17 Pro" "iPad Pro 13-inch (M5)")
for d in "${devices[@]}"; do
  xcrun simctl boot "$d" 2>/dev/null || true
  xcrun simctl bootstatus "$d" >/dev/null
  current="$(xcrun simctl spawn "$d" defaults read .GlobalPreferences AppleLanguages 2>/dev/null | tr -d ' \n()"' || true)"
  if [ "${current%%,*}" != "$lang" ]; then
    xcrun simctl spawn "$d" defaults write .GlobalPreferences AppleLanguages -array "$lang"
    xcrun simctl spawn "$d" defaults write .GlobalPreferences AppleLocale -string "$locale"
    # The language applies from the next boot.
    xcrun simctl shutdown "$d"
    xcrun simctl boot "$d"
    xcrun simctl bootstatus "$d" >/dev/null
  fi
  for service in microphone speech-recognition; do
    xcrun simctl privacy "$d" grant "$service" "${HERMES_BUNDLE_ID_PREFIX:-dev.hermes.local}.app" 2>/dev/null || true
  done
  SCREENSHOT_DIR="$out" TEST_RUNNER_SCREENSHOT_DIR="$out" TEST_RUNNER_SCREENSHOT_LANGUAGE="$lang" \
    xcodebuild test -project Hermes.xcodeproj -scheme HermesApp \
    -only-testing:HermesUITests -destination "platform=iOS Simulator,name=$d" \
    -derivedDataPath "${DERIVED_DATA:-$HOME/Library/Caches/hermes-ios/DerivedData}" CODE_SIGNING_ALLOWED=NO -quiet || true
done
ls "$out"
