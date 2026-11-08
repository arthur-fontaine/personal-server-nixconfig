#!/bin/bash
# Build phase of HermesUI (design-rules 9.4): builds Tools/DesignCheck for the Mac, then fails the
# build on any styling that bypasses HermesUI. Also runnable by hand from apps/hermes-ios.
set -euo pipefail
root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
scratch="${HOME}/Library/Caches/hermes-ios/DesignCheck"
# Xcode's environment targets iOS (SDKROOT, ARCHS…): build the tool with a clean one for the Mac.
# GIT_CONFIG_GLOBAL: a global config may rewrite GitHub's HTTPS URLs to SSH (README).
/usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" GIT_CONFIG_GLOBAL=/dev/null \
  DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
  xcrun --sdk macosx swift build -c release --product design-check \
  --package-path "$root/Tools/DesignCheck" --scratch-path "$scratch" -q
"$scratch/release/design-check" \
  --screens "$root/HermesApp/Views" "$root/HermesApp/Call/CallView.swift" "$root/HermesWidgets" \
  --ui "$root/HermesUI/Sources" \
  --legacy "$root/Tools/DesignCheck/phase2-screens.txt"
