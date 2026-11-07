#!/bin/bash
# Screenshots of every screen, portrait and landscape, on an iPhone and an iPad simulator.
# Usage: scripts/screenshots.sh <out-dir> ["iPhone 17 Pro" "iPad Pro 13-inch (M5)"]
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(cd "${1:?out dir}" && pwd)"; shift || true
devices=("${@:-}")
[ -n "${devices[0]:-}" ] || devices=("iPhone 17 Pro" "iPad Pro 13-inch (M5)")
for d in "${devices[@]}"; do
  xcrun simctl boot "$d" 2>/dev/null || true
  for service in microphone speech-recognition; do
    xcrun simctl privacy "$d" grant "$service" "${HERMES_BUNDLE_ID_PREFIX:-dev.hermes.local}.app" 2>/dev/null || true
  done
  SCREENSHOT_DIR="$out" TEST_RUNNER_SCREENSHOT_DIR="$out" xcodebuild test -project Hermes.xcodeproj -scheme HermesApp \
    -only-testing:HermesUITests -destination "platform=iOS Simulator,name=$d" \
    -derivedDataPath "${DERIVED_DATA:-$HOME/Library/Caches/hermes-ios/DerivedData}" CODE_SIGNING_ALLOWED=NO -quiet || true
done
ls "$out"
