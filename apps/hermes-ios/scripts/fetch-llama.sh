#!/bin/bash
# Fetches llama.cpp's prebuilt Apple XCFramework (Metal, with mtmd) into Vendor/, pinned and
# checksum-verified. XcodeGen runs it before generating (project.yml, preGenCommand).
# The release ships iOS device and macOS slices only: the app links it for iphoneos builds
# (call mode on device), simulator builds fall back to Apple's speech.
# Source: https://github.com/ggml-org/llama.cpp/releases/tag/b12192
set -euo pipefail
BUILD=b12192
SHA256=72f9d4c355ddc9b4364cc8e99c585569557565465e9a2778908b24b503b6b724
cd "$(dirname "$0")/.."
dest=Vendor/llama.xcframework
stamp=Vendor/.llama-$BUILD
[ -f "$stamp" ] && [ -d "$dest" ] && exit 0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$BUILD/llama-$BUILD-xcframework.zip"
echo "$SHA256  $tmp/llama.zip" | shasum -a 256 -c - >/dev/null
unzip -q "$tmp/llama.zip" -d "$tmp/x"
rm -rf Vendor/llama.xcframework Vendor/.llama-*
mkdir -p Vendor
mv "$tmp/x/build-apple/llama.xcframework" "$dest"
touch "$stamp"
echo "llama.cpp $BUILD -> $dest"
